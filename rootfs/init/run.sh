#!/bin/sh

set -e
# set -x

# -------------------------------------------------------------------------------------------------

. /init/output.sh

HOSTNAME=$(hostname -f)

SAMBA_PROCESS_MODEL=${SAMBA_PROCESS_MODEL:-prefork}

SAMBA_DC_DOMAIN=${SAMBA_DC_DOMAIN:-smb}
SAMBA_DC_REALM=${SAMBA_DC_REALM:-MATRIX.LAN}
SAMBA_DC_DNS_BACKEND=${SAMBA_DC_DNS_BACKEND:-SAMBA_INTERNAL}

SAMBA_DEBUGLEVEL=${SAMBA_DEBUGLEVEL:-0}
SAMBA_PROVISION_DEBUGLEVEL=${SAMBA_PROVISION_DEBUGLEVEL:-0}

SAMBA_TARGET_DIR=${SAMBA_TARGET_DIR:-/srv}

SAMBA_CONF_FILE="${SAMBA_TARGET_DIR}/etc/smb.conf"


SAMBA_OPTIONS=${SAMBA_OPTIONS:-}

[[ -n "${SAMBA_HOST_IP}" ]] && SAMBA_OPTIONS="${SAMBA_OPTIONS} --host-ip=${SAMBA_HOST_IP}"

SETUP_LOCK_FILE="${SAMBA_TARGET_DIR}/etc/.setup.lock.do.not.remove"

pass=$(< /dev/urandom tr -dc A-Z-a-z-0-9 | head -c20; echo)

SAMBA_DC_ADMIN_PASSWD=${SAMBA_DC_ADMIN_PASSWD:-${pass}}
KERBEROS_PASSWORD=${KERBEROS_PASSWORD:-${pass}}

#log_debug "Samba password set to   : $SAMBA_DC_ADMIN_PASSWD"
#log_debug "Kerberos password set to: $KERBEROS_PASSWORD"

# we need the export for kdb5_util
export KERBEROS_PASSWORD
export SAMBA_DC_REALM
export HOSTNAME
export SETUP_LOCK_FILE

# -------------------------------------------------------------------------------------------------

finish() {
  rv=$?
  log_INFO "exit with signal '${rv}'"

  if [[ ${rv} -gt 0 ]]
  then
    sleep 4s
  fi

  if [[ "${DEBUG}" = "true" ]]
  then
    caller
  fi

  log_info ""

  exit ${rv}
}

trap finish SIGINT SIGTERM INT TERM EXIT


setup() {

  [[ -f "${SETUP_LOCK_FILE}" ]] && return

  # Configure the AD DC
  if [[ ! -f "${SAMBA_CONF_FILE}" ]]
  then
    mkdir -p \
      ${SAMBA_TARGET_DIR}/etc \
      ${SAMBA_TARGET_DIR}/lib \
      ${SAMBA_TARGET_DIR}/log

    if [[ -d /var/lib/krb5kdc ]]
    then
      rm -rf /var/lib/krb5kdc
      [[ -d ${SAMBA_TARGET_DIR}/krb5kdc ]] || mkdir ${SAMBA_TARGET_DIR}/krb5kdc
      ln -sf ${SAMBA_TARGET_DIR}/krb5kdc /var/lib/krb5kdc
    fi

    log_info "${SAMBA_DC_DOMAIN} - Begin Domain Provisioning"

    samba-tool domain provision \
      ${SAMBA_OPTIONS} \
      --use-rfc2307 \
      --domain=${SAMBA_DC_DOMAIN} \
      --realm=${SAMBA_DC_REALM} \
      --server-role=dc \
      --adminpass=${SAMBA_DC_ADMIN_PASSWD} \
      --dns-backend=${SAMBA_DC_DNS_BACKEND} \
      --targetdir=${SAMBA_TARGET_DIR} \
      --debuglevel=${SAMBA_PROVISION_DEBUGLEVEL}

    result=$?

#    log_debug "result: ${result}"

    log_info "${SAMBA_DC_DOMAIN} - Domain Provisioned Successfully"

    cp /etc/krb5.conf.tpl /etc/krb5.conf
    cat ${SAMBA_TARGET_DIR}/private/krb5.conf >> /etc/krb5.conf

    cat << EOF >> /etc/krb5.conf
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
EOF

# cat /etc/krb5.conf

    # cp -v ${SAMBA_TARGET_DIR}/private/krb5.conf /etc/krb5.conf

    log_info "create kerberos database"
    # Create Kerberos database
    expect /init/build/kdb5_util_create.expect

    log_info "export kerberos keytab for use with sssd"
    # Export kerberos keytab for use with sssd
    samba-tool domain exportkeytab \
      ${SAMBA_TARGET_DIR}/etc/krb5.keytab \
      --configfile=${SAMBA_CONF_FILE} \
      --debuglevel=${SAMBA_PROVISION_DEBUGLEVEL} \
      --principal ${HOSTNAME}\$

    # add dns-forwarder if required
    if [[ -n "${SAMBA_DNS_FORWARDER}" ]]
    then
      log_info "add dns-forwarder if required"
      sed -i \
        "s/dns forwarder.*$/dns forwarder = ${SAMBA_DNS_FORWARDER}/" \
        ${SAMBA_CONF_FILE}
    fi

#    sed -i '8 a\\ttls enabled  = yes' /etc/samba/smb.conf
#    sed -i '9 a\\ttls keyfile  = tls/key.pem' /etc/samba/smb.conf
#    sed -i '10 a\\ttls certfile = tls/cert.pem' /etc/samba/smb.conf
#    sed -i '11 a\\ttls cafile   = tls/ca.pem' /etc/samba/smb.conf

    if [[ -f /etc/samba/smb.conf.tpl ]]
    then
      sed \
        -e "s|%NETBIOS_NAME%|$(hostname -s | tr '[:lower:]' '[:upper:]')|" \
        -e "s|%REALM%|${SAMBA_DC_REALM}|" \
        -e "s|%WORKGROUP%|$(echo ${SAMBA_DC_DOMAIN} | tr '[:lower:]' '[:upper:]')|" \
        -e "s|%SAMBA_TARGET_DIR%|${SAMBA_TARGET_DIR}|" \
        -e "s|%ALLOW_DNS_UPDATES%|secure|" \
        -e "s|%BIND_INTERFACES_ONLY%|yes|" \
        -e "s|%DOMAIN_LOGONS%|yes|" \
        -e "s|%DOMAIN_MASTER%|no|" \
        -e "s|%INTERFACES%|lo eth0|" \
        -e "s|%LOG_LEVEL%|1|" \
        -e "s|%WINBIND_TRUSTED_DOMAINS_ONLY%|no|" \
        -e "s|%WINBIND_USE_DEFAULT_DOMAIN%|yes|" \
        /etc/samba/smb.conf.tpl > "${SAMBA_CONF_FILE}"
    fi

    echo 'root = administrator' > ${SAMBA_TARGET_DIR}/etc/smbusers

    #[[ -d ${SAMBA_TARGET_DIR}/etc/conf.d ]] || mkdir -p ${SAMBA_TARGET_DIR}/etc/conf.d

    for file in $(ls -A /etc/samba/conf.d/*.conf.tpl 2> /dev/null)
    do
      dirname=$(dirname ${file})
      filename=$(basename ${file} .tpl)
      sed \
        -e "s|%SAMBA_TARGET_DIR%|${SAMBA_TARGET_DIR}|" \
        -e "s|%SAMBA_DC_REALM%|${SAMBA_DC_REALM}|" \
        ${file} > ${dirname}/${filename}

      echo "include = ${dirname}/${filename}" >> "${SAMBA_CONF_FILE}"
    done

    #cp -ar /etc/samba       /srv/etc/
    #cp -a  /etc/krb5*       /srv/etc/
    #cp -a  /var/lib/krb5kdc /srv/

    # Mark samba as setup
    touch "${SETUP_LOCK_FILE}"

    # smbd -b | egrep "LOCKDIR|STATEDIR|CACHEDIR|PRIVATE_DIR"
    # smbclient -L localhost -U% --configfile=/srv/etc/samba/smb.conf
    # smbclient //localhost/netlogon -UAdministrator -c 'ls' --configfile=/srv/etc/samba/smb.conf
    # ldapsearch -H ldaps://localhost -x -LLL -z 0 -D "Administrator@MATRIX.LAN"  -w "krazb4re+H5" -b "DC=samba,DC=lan"
  fi
}

prepare() {

  log_debug "use '${SAMBA_DC_ADMIN_PASSWD}' as DC admin password"
  log_debug "use '${KERBEROS_PASSWORD}' as kerberos password"

  # Fix nameserver
  echo -e "search ${SAMBA_DC_REALM}\nnameserver 127.0.0.1" > /etc/resolv.conf
  echo -e "127.0.0.1 ${HOSTNAME} localhost" > /etc/hosts
  echo -e "${HOSTNAME}" > /etc/hostname

  [[ -d /var/log/samba/cores ]] || mkdir -pv /var/log/samba/cores

  chmod -R 0700 /var/log/samba

#   find / -name krb5*

  #if [[ ! -f "/var/lib/krb5kdc/principal" ]]
  #then
  #  cp -a /srv/krb5kdc   /var/lib/
  #  cp -a /srv/etc/krb5* /etc/
  #fi

  # samba --interactive --debuglevel=3 --debug-stderr --configfile=/srv/etc/samba/smb.conf
}

start_samba() {

  log_info "start init process ..."

  samba_opts=
  samba_opts="${samba_opts} --configfile=${SAMBA_CONF_FILE}"
  samba_opts="${samba_opts} --model=${SAMBA_PROCESS_MODEL}"
  samba_opts="${samba_opts} --interactive"

  if [[ ${SAMBA_DEBUGLEVEL} -gt 0 ]]
  then
    samba_opts="${samba_opts} --leak-report"
    samba_opts="${samba_opts} --leak-report-full"
    samba_opts="${samba_opts} --debuglevel=${SAMBA_DEBUGLEVEL}"
    samba_opts="${samba_opts} --debug-stderr"
  fi

  samba ${samba_opts}
#set -x
#  samba \
#    --configfile=${SAMBA_CONF_FILE} \
#    --model=${SAMBA_PROCESS_MODEL} \
#    --leak-report \
#    --leak-report-full \
#    --debuglevel=${SAMBA_DEBUGLEVEL} \
#    --debug-stderr \
#    --interactive
}

# -------------------------------------------------------------------------------------------------

run() {

#  whoami
#  sleep 5s

  setup

  prepare

  . /init/import_users.sh

  start_samba
}

run
