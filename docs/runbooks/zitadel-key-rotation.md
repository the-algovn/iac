# Zitadel signing-key rotation (Kong pins the public key)
Kong OSS can't fetch JWKS; the active public key is a committed Secret in
platform/kong/manifests/. Rotation is DELIBERATE and zero-downtime (jwt plugin matches
credentials by token kid — old+new coexist). PAT: password manager
`zitadel-iam-admin-sa-pat`, issued for the chart-created machine user `iam-admin`
(IAM_OWNER — see docs/runbooks/zitadel.md step 3). `ZPAT=$(cat ~/.secrets/zpat | tr -d
'[:space:]')` or wherever the current PAT is staged locally; never print it.
Drill last passed: 2026-07-13.

1. Create the new web key:
   curl -s -X POST -H "Authorization: Bearer $ZPAT" -H "Content-Type: application/json" \
     https://id.algovn.com/v2beta/web_keys \
     -d '{"rsa":{"bits":"RSA_BITS_2048","hasher":"RSA_HASHER_SHA256"}}'
   (bare `{"rsa":{}}` 400s on this Zitadel version — "invalid RSA.Bits: value must not be
   in list [RSA_BITS_UNSPECIFIED]" — the bits/hasher enums must be given explicitly; use the
   values above to match the existing keys.)
   → note returned id. GET https://id.algovn.com/oauth/v2/keys now lists an extra key.
2. Extract new kid+PEM (task-8 python one-liner works; pick keys[] entry with the new kid),
   add Secret platform/kong/manifests/zitadel-jwt-<newkid10>.yaml (copy existing file's shape;
   use the first 10 chars of the kid — 8 is not always enough to disambiguate, see task-8
   report), append its name to the consumer's credentials list, add to kustomization,
   validate, push, sync the `kong` Argo app (poll via kubectl jsonpath + refresh-annotate;
   no argocd CLI in this environment).
3. Activate: curl -s -X POST -H "Authorization: Bearer $ZPAT" \
     https://id.algovn.com/v2beta/web_keys/<id>/activate
   New tokens now carry the new kid; old tokens keep validating (old credential still present).
4. Soak ≥ max token lifetime (default 12h access tokens), then delete the retired web key:
   curl -s -X DELETE -H "Authorization: Bearer $ZPAT" https://id.algovn.com/v2beta/web_keys/<oldid>
   and remove the old Secret + credentials entry from git; push, sync.
5. Verify: mint fresh token (client_credentials) → protected route 200; JWKS shows 1 key.
If the API paths 404 (Zitadel upgrade moved them): https://zitadel.com/docs/apis/resources/webkey_service_v2
