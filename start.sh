#!/bin/bash -e

usage() {
  exitcode=0
  if [[ -n $1 ]]; then
    echo "Error: $*"
    echo
    exitcode=1
  fi

  cat <<EOF
usage: $0 [domain] [email] [json-rpc-path1] [json-rpc-host1] [json-rpc-path2] [json-rpc-host2] ...

Starts a Docker container running an Apache2 server that provides a https proxy
into the specified JSON RPC endpoint.  The TLS certificate is automatically
created using Let's Encrypt.

  domain          The fully-qualified domain name for this machine
  email           Contact email provided to Let's Encrypt
  json-rpc-path1  URL path to map to the the first JSON RPC endpoint
  json-rpc-host1  Host name of the first JSON RPC endpoint (port 8899 is assumed)
  json-rpc-path2  ...
  json-rpc-host2  ...

EOF

  exit $exitcode
}

cd "$(dirname "$0")"

DOMAIN="$1"
EMAIL="$2"
[[ -n $DOMAIN ]] || usage "domain not specified"
[[ -n $EMAIL ]] || usage "email not specified"

proxyList=()

shift 2
while [[ -n $1 ]]; do
  [[ -n $2 ]] || usage "json-rpc-host not specified"
  proxyList+=("$1 $2:8899")
  shift 2
done

[[ ${#proxyList[@]} -gt 0 ]] || usage "No JSON RPC endpoints specified"
for info in "${proxyList[@]}"; do
  echo $info
done

IMAGE=solana-json-rpc-https-proxy
CONTAINER=$IMAGE

rm -rf sites-available/
mkdir sites-available/

addProxyPass() {
  local path=$1
  local rpcEndPoint=$2
  echo "ProxyPass $path http://$rpcEndPoint/"
  echo "ProxyPassReverse $path http://$rpcEndPoint/"
}

addProxyPasses() {
  declare info
  for info in "${proxyList[@]}"; do
    addProxyPass $info
  done
}

cat > sites-available/solana-json-rpc-https-proxy.conf <<EOF
<IfModule mod_ssl.c>
  <VirtualHost *:443>
    ServerName $DOMAIN
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Port "443"

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem

    # https://mozilla.github.io/server-side-tls/ssl-config-generator/
    # HSTS (mod_headers is required) (15768000 seconds = 6 months)
    Header always set Strict-Transport-Security "max-age=15768000"

    ErrorLog \${APACHE_LOG_DIR}/error.log
    DocumentRoot /var/www/webproxy-root

    ProxyRequests Off
    ProxyPreserveHost On
    AllowEncodedSlashes NoDecode

    ProxyPassMatch /.well-known/acme-challenge/(.*) !
    $(addProxyPasses)
  </VirtualHost>
</IfModule>

<VirtualHost *:80>
  ServerName $DOMAIN
  RequestHeader set X-Forwarded-Proto "http"
  RequestHeader set X-Forwarded-Port "80"

  ErrorLog ${APACHE_LOG_DIR}/error.log
  DocumentRoot /var/www/webproxy-root

  ProxyRequests Off
  ProxyPreserveHost On
  AllowEncodedSlashes NoDecode

  ProxyPassMatch /.well-known/acme-challenge/(.*) !
  $(addProxyPasses)
</VirtualHost>
EOF

(
  set -x
  docker build -t $IMAGE .
)

DEV=false
#DEV=true
if $DEV; then
  mkdir -p log/{apache2,letsencrypt}/
  mkdir -p etc-letsencrypt/
fi

(
  set +ex
  docker stop $CONTAINER
  docker rm $CONTAINER
) || true

ARGS=(
  --env "EMAIL=$EMAIL"
  --env "DOMAIN=$DOMAIN"
  "--stop-signal=SIGPWR"
  --tty
  --detach
  --publish 80:80
  --publish 443:443
  --name "$CONTAINER"
)

if $DEV; then
  ARGS+=(
    --volume "$PWD/log/apache2:/var/log/apache2"
    --volume "$PWD/log/letsencrypt:/var/log/letsencrypt"
    --volume "$PWD/etc-letsencrypt:/etc/letsencrypt"
    --rm
  )
else
  ARGS+=("--restart=always")
fi

(
  set -x
  docker run "${ARGS[@]}" $IMAGE
)

set +e
echo
echo ===================================================================
echo Container $CONTAINER is now running. To monitor progress run:
echo
echo "$ docker logs -f $CONTAINER"
echo
echo Apache2 logs can be found in /var/log/apache2/:
echo
(
  set -x
  docker exec solana-json-rpc-https-proxy ls -l /var/log/apache2/
)
echo
echo
echo "Let's Encrypt log files can be found /var/log/letsencrypt/:"
echo
(
  set -x
  docker exec solana-json-rpc-https-proxy ls -l /var/log/letsencrypt/
)

if ! $DEV; then
  echo
  echo "The Let's Encrypt certificate is stored in /etc/letsencrypt/"
  echo
  echo "Warning: If you recreate the $CONTAINER container,"
  echo "         the current certificate will be lost."
  echo "         Do this frequently enough and you will be rate limited."
  echo "         See details at https://letsencrypt.org/docs/rate-limits/"
fi

echo
echo ===================================================================
echo "Test the proxy by running once the Let's Encrypt certificate has been"
echo "successfully issued:"
echo
echo "  $ curl -X POST https://$DOMAIN"
echo
echo "The expected response from curl is:"
echo '  "Supplied content type is not allowed. Content-Type: application/json is required"'
echo
