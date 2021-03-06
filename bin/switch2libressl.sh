#!/bin/sh
#
# set -x

# switch a tinderbox image from OpenSSL to LibreSSL
# inspired by https://wiki.gentoo.org/wiki/Project:LibreSSL

backlog="/tmp/backlog"

echo
echo "=================================================================="
echo

if [[ ! -e $backlog ]]; then
  echo " don't run this script outside of a tinderbox image !"
  exit 1
fi

# define the SSL vendor in make.conf
#
cat << EOF >> /etc/portage/make.conf
CURL_SSL="libressl"
USE="\${USE} -openssl -gnutls libressl"
EOF

# mask OpenSSL
#
echo "dev-libs/openssl" > /etc/portage/package.mask/openssl

mkdir -p /etc/portage/profile

# unmask LibreSSL related USE flags
#
cat << EOF >> /etc/portage/profile/use.stable.mask
-libressl
-curl_ssl_libressl
EOF

# set package specific USE flags, otherwise switch to LibreSSL or @system often fails
#
cat << EOF > /etc/portage/package.use/libressl
dev-lang/python           -tk
dev-qt/qtsql              -mysql
EOF
chmod a+rw /etc/portage/package.use/libressl

# few unstable packages needed even at a stable image
#
grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
if [[ $? -eq 1 ]]; then
  cat << EOF > /etc/portage/package.accept_keywords/libressl
>=mail-mta/ssmtp-2.64-r3
EOF
fi

# unmerge of OpenSSL triggers already a @preserved-rebuild in job.sh
# but use "%" here to definitely bail out if it would fail
#
cat << EOF >> $backlog.1st
%emerge @preserved-rebuild
%emerge -C openssl
EOF

# fetch before OpenSSL is uninstalled and the fetch command itfself
# wouldn't work until being rebuild against LibreSSL
#
emerge -f dev-libs/libressl net-misc/openssh mail-mta/ssmtp net-misc/wget dev-lang/python
exit $?
