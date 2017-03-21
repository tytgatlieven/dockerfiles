#!/bin/sh

sed -i -e "s/<UPLOAD_MAX_SIZE>/$UPLOAD_MAX_SIZE/g" /etc/nginx/nginx.conf /etc/php7.1/php-fpm.conf \
       -e "s/<PHP_MEMORY_LIMIT>/$PHP_MEMORY_LIMIT/g" /etc/nginx/nginx.conf /etc/php7.1/php-fpm.conf \
       -e "s/<APC_SHM_SIZE>/$APC_SHM_SIZE/g" /etc/php7.1/conf.d/apcu.ini \
       -e "s/<OPCACHE_MEM_SIZE>/$OPCACHE_MEM_SIZE/g" /etc/php7.1/conf.d/00_opcache.ini \
       -e "s/<REDIS_MAX_MEMORY>/$REDIS_MAX_MEMORY/g" /etc/redis.conf \
       -e "s/<CRON_MEMORY_LIMIT>/$CRON_MEMORY_LIMIT/g" /etc/s6.d/cron/run \
       -e "s/<CRON_PERIOD>/$CRON_PERIOD/g" /etc/s6.d/cron/run

# Put the configuration and apps into volumes
ln -sf /config/config.php /nextcloud/config/config.php &>/dev/null
ln -sf /apps2 /nextcloud &>/dev/null

# Create folder for php sessions if not exists
if [ ! -d /data/session ]; then
  mkdir -p /data/session;
fi

echo "Updating permissions..."
for dir in /nextcloud /data /config /apps2 /etc/nginx /etc/php7.1 /var/log /var/lib/nginx /tmp /etc/s6.d; do
  if $(find $dir ! -user $UID -o ! -group $GID|egrep '.' -q); then
    echo "Updating permissions in $dir..."
    chown -R $UID:$GID $dir
  else
    echo "Permissions in $dir are correct."
  fi
done
echo "Done updating permissions."

#Wait until the database is running
if [ $DB_TYPE = pgsql ]; then
       until pg_isready -h DB_HOST; do
              >&2 echo "Not yet starting instance: Postgres host:$DB_HOST is not (yet) available - retry in 1s"
              sleep 1
       done
fi

if [ $DB_TYPE = mysql ]; then
       until mysqladmin ping -h"$DB_HOST" --silent; do
              >&2 echo "Not yet starting instance: mysql host:$DB_HOST is not (yet) available - retry in 1s"
              sleep 1
       done
fi

if [ ! -f /config/config.php ]; then
    # New installation, run the setup
    /usr/local/bin/setup.sh
else
    occ upgrade
    if [ \( $? -ne 0 \) -a \( $? -ne 3 \) ]; then
        echo "Trying ownCloud upgrade again to work around ownCloud upgrade bug..."
        occ upgrade
        if [ \( $? -ne 0 \) -a \( $? -ne 3 \) ]; then exit 1; fi
        occ maintenance:mode --off
        echo "...which seemed to work."
    fi
fi

#This config allows easy setup when running behind nginx-proxy with nginx-gen container
# update the trusted_domain to the VIRTUAL_HOST if defined
if [ ! -z $VIRTUAL_HOST ]; then
    sed -i "s/localhost/$VIRTUAL_HOST/g" /config/config.php
fi

# if LETSENCRYPT_HOST is defined we assume we are using https
if [ ! -z $LETSENCRYPT_HOST ]; then
    sed -i "s/http:/https:/g" /config/config.php
fi

exec su-exec $UID:$GID /bin/s6-svscan /etc/s6.d
