#!/usr/bin/env bash
# Тестовые сертификаты для tests/tls.sh в каталог $1: корень RSA, промежуточный
# ECDSA P-384, листы ECDSA P-256 и RSA, лист для клиентов, просроченный,
# ограниченный nameConstraints и чужой корень с тем же именем.
set -euo pipefail
cd "$1"
q() { "$@" >/dev/null 2>&1; }
cat > ext.cnf <<'X'
[inter]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
extendedKeyUsage=serverAuth
[leaf]
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:test.local,DNS:*.wild.local,DNS:allowed.local,IP:127.0.0.1
[leaf_client]
basicConstraints=CA:FALSE
extendedKeyUsage=clientAuth
subjectAltName=DNS:test.local
[nc]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign
nameConstraints=critical,permitted;DNS:allowed.local
X
root() {
	q openssl req -x509 -newkey "$2" "${@:3}" -nodes -keyout "$1.key" -out "$1.pem" -days 3650 -subj "/CN=Khrip Test Root" \
		-addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
}
# имя, запрос, издатель, расширения, дни, хеш
sign() {
	q openssl x509 -req -in "$2.csr" -CA "$3.pem" -CAkey "$3.key" -CAcreateserial -out "$1.pem" -days "$5" -extfile ext.cnf -extensions "$4" "-$6"
}
root root rsa:2048
root other ec -pkeyopt ec_paramgen_curve:P-256
q openssl ecparam -name secp384r1 -genkey -noout -out inter.key
q openssl req -new -key inter.key -out inter.csr -subj "/CN=Khrip Test Intermediate"
sign inter inter root inter 1000 sha256
q openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
q openssl req -new -key leaf.key -out leaf.csr -subj "/CN=test.local"
sign leaf leaf inter leaf 300 sha384
q openssl req -new -newkey rsa:2048 -nodes -keyout leafrsa.key -out leafrsa.csr -subj "/CN=test.local"
sign leafrsa leafrsa inter leaf 300 sha256
sign leafclient leaf inter leaf_client 300 sha256
q openssl ecparam -name prime256v1 -genkey -noout -out nc.key
q openssl req -new -key nc.key -out nc.csr -subj "/CN=Constrained CA"
sign nc nc root nc 1000 sha256
sign leafnc leaf nc leaf 300 sha256
# просроченный (2020 год): даты задаёт только «openssl ca»
mkdir -p ca.d
: >ca.d/index.txt
echo 1000 >ca.d/serial
cat > ca.cnf <<'X'
[ca]
default_ca = d
[d]
dir = ca.d
database = ca.d/index.txt
new_certs_dir = ca.d
serial = ca.d/serial
default_md = sha256
policy = p
[p]
commonName = supplied
X
q openssl ca -batch -config ca.cnf -cert inter.pem -keyfile inter.key -in leaf.csr -out leafexpired.pem \
	-startdate 20200101000000Z -enddate 20210101000000Z -extfile ext.cnf -extensions leaf -notext
cat leaf.pem inter.pem > chain_ec.pem
cat leafrsa.pem inter.pem > chain_rsa.pem
