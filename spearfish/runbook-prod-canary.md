# Runbook: canary a new fork Doris build in prod (be-/fe-4.1.5-p67552-1)

Destination: `devops-terraform-k8s/docs/runbooks/doris-4.1.5-canary.md`. It lives in the fork
until it is copied there. **A person applies every step. There is no dev Doris**
(`dev.tfvars doris_enabled = false`; dev and stg use prod Doris), so prod is canaried one BE pod at
a time instead.

## 0. Preconditions

- The images exist in ACR and you have checked them. Don't trust the push exit code: on 2026-09-11
  an expired token produced a "successful" push that never landed.
  ```bash
  az acr manifest show-metadata -r spearfish -n apache/doris:be-4.1.5-p67552-1 --query digest -o tsv
  az acr manifest show-metadata -r spearfish -n apache/doris:fe-4.1.5-p67552-1 --query digest -o tsv
  ```
- Record the fork commit the images were built from: `org.opencontainers.image.revision` label, or
  `git rev-parse HEAD` of the build. Call it `$COMMIT`, and `$SHORT` for its first 8 characters.
- Set `SET GLOBAL enable_count_push_down_for_external_table = false` for the whole FE/BE skew
  window (FE 4.1.5 with BE 4.1.4). Lesson from 2026-09-11: the COUNT(*) fast path returns garbage
  under skew. Re-enable it after step 4.

## 1. Terraform values

`prod.tfvars` is gitignored. Change these two lines (line numbers from the build PC's copy):

```hcl
# prod.tfvars:357
doris_be_image_tag = "be-4.1.5-p67552-1"   # was "be-4.1.4-p67552-2"
# prod.tfvars:363
doris_fe_image_tag = "fe-4.1.5-p67552-1"   # was "fe-4.1.4"
```

Add the same two lines, commented, to `prod.example.tfvars` next to `doris_be_replicas = 4`.
Also update the PROD OVERRIDE notes in `terraform/variables.tf` (`doris_fe_image_tag`,
`doris_be_image_tag`).

## 2. FE first (forward-only)

Apply with **only** the FE line changed. FE metadata upgrades are forward-only: never roll the FE
back below 4.1.5 after this. The operator rolls the FEs one at a time; check that quorum (2 of 3)
holds throughout:

```bash
kubectl --context prod-sf-aks-us-east2 -n doris get pods -l app.kubernetes.io/component=fe -w
kubectl --context prod-sf-aks-us-east2 -n doris exec doriscluster-helm-fe-0 -- mysql -h127.0.0.1 -P9030 -uroot -p -e "SHOW FRONTENDS\G" | grep -E 'Alive|Version'
```

## 3. BE canary: only `doriscluster-helm-be-3`

**The DorisCluster CRD has no rollout partition.** Operator chart `doris-operator-25.8.0`: the
`dorisclusters` CRD has no `updateStrategy`, `rollingUpdate` or `partition` field. The operator
owns the BE StatefulSet, so the canary is done on the StatefulSet with the operator paused.

```bash
CTX=--context=prod-sf-aks-us-east2
# 3a. Pause reconciliation so the operator cannot undo the partition or roll every BE.
kubectl $CTX -n doris scale deploy -l app.kubernetes.io/name=doris-operator --replicas=0
# 3b. Partition first, then the image: only ordinals >= 3 take the new template.
kubectl $CTX -n doris patch sts doriscluster-helm-be --type=merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":3}}}}'
kubectl $CTX -n doris set image sts/doriscluster-helm-be be=spearfish.azurecr.io/apache/doris:be-4.1.5-p67552-1
# 3c. Verify the RENDERED StatefulSet, not the CR.
kubectl $CTX -n doris get sts doriscluster-helm-be -o jsonpath='{.spec.updateStrategy}{"\n"}{.spec.template.spec.containers[*].image}{"\n"}'
kubectl $CTX -n doris get pods -l app.kubernetes.io/component=be -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,REV:.metadata.labels.controller-revision-hash
```

Check the container name used by `set image` against the rendered StatefulSet first. Expected
result: be-0, be-1 and be-2 keep the old revision and image; only be-3 restarts.

Do **not** run `terraform apply` while the operator is paused. Terraform would change the CR, and
the operator would roll every BE when it comes back.

## 4. Soak 24h on be-3, then roll the rest

Post-deploy checks on be-3, then on every BE after the full roll:

```bash
# Image is the ACR repo apache/doris, NOT spearfish.azurecr.io/dockerhub/apache/doris.
kubectl $CTX -n doris get pod doriscluster-helm-be-3 -o jsonpath='{.spec.containers[0].image}{"\n"}{.status.containerStatuses[0].imageID}{"\n"}'
az acr manifest show-metadata -r spearfish -n apache/doris:be-4.1.5-p67552-1 --query digest -o tsv
#   -> the digest in imageID (after '@') must equal the ACR digest.
kubectl $CTX -n doris logs doriscluster-helm-be-3 | grep -m1 'Current BE git commitID'
#   -> must print $SHORT (the fork commit), not c2a275c5 or an upstream hash.
```

Soak for 24h. This must include the Watchdog `LatticeStorageIntegrityService` runs (every 30 min)
and the `$files` repro, run by hand at least 50 times:

```sql
SELECT content AS Content, substring_index(file_path, '://', 1) AS Scheme, count(*) AS FileCount,
       min(file_path) AS ExamplePath
FROM `iceberg_lakehouse`.`spearfish_prod`.`silver_qa_evaluations$files`
GROUP BY content, substring_index(file_path, '://', 1) ORDER BY content;
```

Pass criteria:
- be-3 has 0 restarts, and there are no `SIGSEGV` or `hollow column` lines in be-3's `be.out`.
- The query's results are unchanged.
- An Iceberg UPDATE/DELETE still writes `abfss://` delete files. This checks c2a275c56; validate
  it the same way as on 2026-09-09.

A `hollow column: a subcolumn is null` query error is a correct failure: the query failed instead
of the process. Capture the query ID and report it.

Roll the rest: lower the partition (`"partition":0`), check each pod with the commands above, then
put the BE line into `prod.tfvars`. Scale the operator back to 1. Run `terraform plan`: it should
show the CR image change only. Apply it and confirm no further BE restarts. If the operator
resets `updateStrategy`, that is expected. Re-enable `enable_count_push_down_for_external_table`.

## Rollback

- BE: `kubectl set image` back to `be-4.1.4-p67552-2` with the partition still at 3, which affects
  be-3 only. Or revert the tfvars line with the operator running.
- FE: **do not roll back.** FE is forward-only.
