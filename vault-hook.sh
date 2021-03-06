#!/usr/bin/env bash

# shellcheck disable=SC1091
source "/etc/dehydrated/vault.inc"

VAULT_TOKEN=""

acquire_token() {
  VAULT_TOKEN=$(curl -s -X POST \
    -d "{\"role_id\":\"${VAULT_ROLE_ID}\",\"secret_id\":\"${VAULT_SECRET_ID}\"}" \
    "${VAULT_ADDRESS}/v1/auth/approle/login" | jq -r .auth.client_token)
}

upload_certificate() {

  local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

  # This hook is called once for each certificate that has been
  # produced. Here you might, for instance, copy your new certificates
  # to service-specific locations and reload the service.
  #
  # Parameters:
  # - DOMAIN
  #   The primary domain name, i.e. the certificate common
  #   name (CN).
  # - KEYFILE
  #   The path of the file containing the private key.
  # - CERTFILE
  #   The path of the file containing the signed certificate.
  # - FULLCHAINFILE
  #   The path of the file containing the full certificate chain.
  # - CHAINFILE
  #   The path of the file containing the intermediate certificate(s).
  # - TIMESTAMP
  #   Timestamp when the specified certificate was created.

  echo " + Storing certificates in ${VAULT_ADDRESS} at ${VAULT_SECRET_BASE}/${DOMAIN}"

  curl \
    --silent \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --request POST \
    -d @<( jq -n --arg cert "$(< "${CERTFILE}" )" \
      --arg key "$(< "${KEYFILE}" )" \
      --arg chain "$(< "${CHAINFILE}" )" \
      --arg fullchain "$(< "${FULLCHAINFILE}" )" \
      --arg timestamp "${TIMESTAMP}" \
      '{data:{cert:$cert,key:$key,chain:$chain,fullchain:$fullchain,timestamp:$timestamp,owner:"letsencrypt"}}' ) \
    "${VAULT_ADDRESS}/v1/${VAULT_SECRET_BASE}/${DOMAIN}"
}

deploy_challenge() {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    # This hook is called once for every domain that needs to be
    # validated, including any alternative names you may have listed.
    #
    # Parameters:
    # - DOMAIN
    #   The domain name (CN or subject alternative name) being
    #   validated.
    # - TOKEN_FILENAME
    #   The name of the file containing the token to be served for HTTP
    #   validation. Should be served by your web server as
    #   /.well-known/acme-challenge/${TOKEN_FILENAME}.
    # - TOKEN_VALUE
    #   The token value that needs to be served for validation. For DNS
    #   validation, this is what you want to put in the _acme-challenge
    #   TXT record. For HTTP validation it is the value that is expected
    #   be found in the $TOKEN_FILENAME file.
}

clean_challenge() {
    # shellcheck disable=SC2034
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    # This hook is called after attempting to validate each domain,
    # whether or not validation was successful. Here you can delete
    # files or DNS records that are no longer needed.
    #
    # The parameters are the same as for deploy_challenge.
}

deploy_cert() {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

    # This hook is called once for each certificate that has been
    # produced. Here you might, for instance, copy your new certificates
    # to service-specific locations and reload the service.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
    # - TIMESTAMP
    #   Timestamp when the specified certificate was created.

  upload_certificate "${@}"
}

unchanged_cert() {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}"

    # This hook is called once for each certificate that is still
    # valid and therefore wasn't reissued.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).

  acquire_token

  CURRENT_SECRET=$(curl --silent \
    --header "X-Vault-Request: true" \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDRESS}/v1/${VAULT_SECRET_BASE}/${DOMAIN}")
  CURRENT_FILE_KEY_SHA=$(openssl pkey -pubout < ${KEYFILE} | sha256sum)
  CURRENT_SECRET_KEY_SHA=$(jq .data.data.key --raw-output <<< "${CURRENT_SECRET}" \
    | openssl pkey -pubout \
    | sha256sum)
  # check if the keys match
  if [[ "${CURRENT_SECRET_KEY_SHA% *}" == "${CURRENT_FILE_KEY_SHA% *}" ]]
  then
    echo " + The certificate is already up to date in ${VAULT_ADDRESS} at ${VAULT_SECRET_BASE}/${DOMAIN}"
  else
    echo "LOADING"
    upload_certificate "${@}"
  fi
}

invalid_challenge() {
    # shellcheck disable=SC2034
    local DOMAIN="${1}" RESPONSE="${2}"

    # This hook is called if the challenge response has failed, so domain
    # owners can be aware and act accordingly.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - RESPONSE
    #   The response that the verification server returned
}

request_failure() {
    # shellcheck disable=SC2034
    local STATUSCODE="${1}" REASON="${2}" REQTYPE="${3}"

    # This hook is called when a HTTP request fails (e.g., when the ACME
    # server is busy, returns an error, etc). It will be called upon any
    # response code that does not start with '2'. Useful to alert admins
    # about problems with requests.
    #
    # Parameters:
    # - STATUSCODE
    #   The HTML status code that originated the error.
    # - REASON
    #   The specified reason for the error.
    # - REQTYPE
    #   The kind of request that was made (GET, POST...)
}

exit_hook() {
  # This hook is called at the end of a dehydrated command and can be used
  # to do some final (cleanup or other) tasks.

  :
}

HANDLER="${1}"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert|unchanged_cert|invalid_challenge|request_failure|exit_hook)$ ]]; then
  "${HANDLER}" "${@}"
fi
