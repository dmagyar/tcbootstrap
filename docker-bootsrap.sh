#!/bin/bash
set -e

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <main.domain>"
    exit 1
fi

export fqdn=$1
export cdir=$(pwd)
echo ">>>> Docker bootstrap starting "

apt-get -y update
apt-get install -y unzip curl git bridge-utils syslog-ng software-properties-common pwgen
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get -y update
apt-get install -y docker-ce

cat >/etc/syslog-ng/conf.d/dockers.conf <<EOF
# syslog-ng dockers log config

options {
    use_dns(no);
    keep_hostname(yes);
    create_dirs(yes);
    ts_format(iso);
};

source s_net_dck { udp(ip(169.254.254.254) port(5514)); };
source s_net_log { udp(ip(169.254.254.254) port(514)); };

rewrite r_net_dck {
    subst ("^/usr/(sbin|bin)/", "", value (PROGRAM));
    subst ("^/(sbin|bin)/", "", value (PROGRAM));
    subst ("/", "-", value (PROGRAM));
    subst ("^-", "", value (PROGRAM));
    subst ("^169.254.254.254$", "", value (HOST));
};

filter f_net_dck { facility(local7); };

destination d_dockers { file("/var/log/dockers/\${YEAR}-\${MONTH}-\${DAY}/\${PROGRAM}.log"); };
destination d_net_log { file("/var/log/dockers/\${YEAR}-\${MONTH}-\${DAY}/\${HOST}.log"); };

log { source(s_net_dck); filter(f_net_dck); rewrite(r_net_dck); destination(d_dockers); flags(final); };
log { source(s_net_log); destination(d_net_log); flags(final); };
EOF

mkdir -p /var/log/dockers 2>/dev/null >/dev/null
chmod 0700 /var/log/dockers

cat >/etc/docker/daemon.json <<EOF
{
        "dns": [
                "8.8.8.8",
                "8.8.4.4"
        ],
        "log-opts": {
                "tag": "{{.Name}}",
		"syslog-facility": "local7",
		"syslog-address": "udp://169.254.254.254:5514",
		"syslog-format": "rfc3164"
        },
        "storage-driver": "overlay2",
        "log-driver": "syslog",
        "userland-proxy": false,
        "tls": true,
        "tlscacert": "/etc/docker/ca.crt",
        "tlscert": "/etc/docker/docker.crt",
        "tlskey": "/etc/docker/docker.key"
}
EOF

cd /etc
curl -fsSL https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.6/EasyRSA-unix-3.0.6.tgz -o - | tar xz
mv EasyRSA-* CA
cd -
cd /etc/CA
mv vars.example vars

./easyrsa init-pki
echo "$fqdn CA" | ./easyrsa build-ca nopass
./easyrsa build-server-full docker nopass

cat <<EOF >x509-types/server
subjectAltName=\${ENV::SAN}
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
extendedKeyUsage = serverAuth,1.3.6.1.5.5.8.2.2
keyUsage = digitalSignature,keyEncipherment,dataEncipherment
EOF

cat <<EOF >x509-types/client
subjectAltName=\${ENV::SAN}
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
extendedKeyUsage = clientAuth
keyUsage = digitalSignature
EOF

export SAN="DNS:$fqdn"
./easyrsa build-server-full $fqdn nopass

cp pki/issued/docker.crt /etc/docker/
cp pki/private/docker.key /etc/docker/
cp pki/ca.crt /etc/docker/
systemctl enable docker
systemctl restart docker
cd -

cat >/etc/systemd/system/docker@.service <<EOF
[Unit]
Description=Docker container for %i
After=docker.service

[Install]
WantedBy=multi-user.target

[Service]
ExecStart=/usr/bin/docker start -a %i
ExecStop=/usr/bin/docker stop -t 120 %i
Restart=always
RestartSec=30s
EOF

cat > /etc/rc.local <<EOF
#!/bin/bash
/sbin/brctl addbr link
echo 1 >/proc/sys/net/ipv4/ip_forward
/sbin/ip a replace 169.254.254.254/32 dev link
/sbin/ip link set dev link up
exit 0
EOF
chmod 0700 /etc/rc.local
/etc/rc.local

systemctl daemon-reload

systemctl restart syslog-ng
systemctl restart docker

echo '. /etc/docker_macros' >> /etc/bash.bashrc

curl -L https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod 0700 /usr/local/bin/docker-compose

cat >/usr/local/bin/logrotate.sh <<EOF
#!/bin/bash
cd /var/log/dockers
# number of days to keep uncompressed
i=2
dd=$(date -d "-$i days" +"%Y-%m-%d")
while [ -d $dd ]; do 
    cd $dd
    tar -oc * | gzip -9 >../$dd.tgz
    cd ..
    rm -rf ./$dd
    i=$((i+1))
    dd=$(date -d "-$i days" +"%Y-%m-%d")
done
EOF

chmod 755 /usr/local/bin/logrotate.sh
cat >/etc/cron.d/logrotate <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
00 2 * * *   root	/usr/local/bin/logrotate.sh
EOF

cat >/etc/docker_macros <<EOF
dstat () {
    (
	echo $'ID\tNAME\tIP\t MEMORY'
	docker ps --no-trunc --format '{{.ID}}:{{.Names}}' | while IFS=: read id name
	do
	    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $id)
	    mem=$(cat /sys/fs/cgroup/memory/docker/$id/memory.usage_in_bytes)
	    if ((mem > 536870912))
	    then
		mem=$((mem/1073741824))
		sfx=G
	    elif ((mem > 524288))
	    then
		mem=$((mem/1048576))
		sfx=M
	    elif ((mem > 512))
	    then
		mem=$((mem/1024))
		sfx=k
	    else
		sfx=""
	    fi
	    printf "%12s\t%s\t\t%s\t%6.1f%s\n" "${id:0:12}" "$name" "${ip:-N/A}" "$mem" "$sfx"
	done
    ) | column -s $'\t' -t
}

dclean () {
    docker rm $(docker ps -q -f status=exited)
    docker rmi $(docker images | grep -e "^<none" | sed 's/  */ /g' | cut -d " " -f 3)
}

dsh () {
    if [ "$#" = "0" ]; then
    	echo -e "Usage: dsh <container-name> [command]\n"
	return
    fi

    term=

    if [ -t 1 ] && [ -t 0 ]; then
    	term=-t
    fi

    if [ "$#" = "1" ]; then
    	docker exec $term -i $1 /bin/bash -i
	return
    fi

    instance=$1
    shift

    docker exec $term -i $instance "$@"
    return
}

alias dip=dstat
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"'
EOF

echo ">>> Docker bootstrap done. "


