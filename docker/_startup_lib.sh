#!/bin/bash

verify_config() {
  # Make sure settings_local.py exists so the app doesn't crash
  if [ ! -f onisite/settings_local.py ]; then
    touch onisite/settings_local.py
  fi
  # Make sure we have a default urls.py
  if [ ! -f onisite/urls.py ]; then
    cp onisite/urls_example.py onisite/urls.py
  fi

  # Prepare the ENV dir if necessary
  if [ ! -d /opt/openoni/ENV ]; then
    /pip-install.sh
  fi
}

replace_ini_data() {
  # Generate a random secret key if that hasn't already happened.  This stays the
  # same after it's first set.
  sed -i "s/!SECRET_KEY!/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 80)/g" /etc/openoni.ini.orig

  # Refresh the environmental config for APP_URL in case it needs to change
  cp /etc/openoni.ini.orig /etc/openoni.ini

  # Add in HTTPPORT from .env file if necessary
  if [[ $HTTPPORT != "" && $HTTPPORT != 80 ]]; then
    sed -i "s|!APP_URL!|!APP_URL!:$HTTPPORT|g" /etc/openoni.ini
  fi

  # Set BASE_URL and public IIIF URL from APP_URL in .env file
  sed -i "s|!APP_URL!|$APP_URL|g" /etc/openoni.ini
}

setup_database() {
  DB_READY=0
  MAX_TRIES=15
  TRIES=0
  while [ $DB_READY == 0 ]
    do
     if
       ! mysql -uroot -hrdbms -p123456 \
         -e 'ALTER DATABASE openoni charset=utf8'
     then
       sleep 5
       let TRIES++
       echo "Looks like we're still waiting for RDBMS ... 5 more seconds ... retry $TRIES of $MAX_TRIES"
       if [ "$TRIES" = "$MAX_TRIES" ]
       then
        echo "Looks like we couldn't get RDBMS running. Could you check settings and try again?"
        echo "ERROR: The database was not setup properly."
        exit 2
       fi
     else
       DB_READY=1
     fi
  done

  echo "setting up a test database ..."
  mysql -uroot -hrdbms -p123456 \
    -e 'USE mysql; GRANT ALL on test_openoni.* TO "openoni"@"%" IDENTIFIED BY "openoni";'

  echo "-------" >&2
  echo "Migrating database" >&2
  source ENV/bin/activate
  /opt/openoni/manage.py migrate
}

prep_webserver() {
  mkdir -p /var/tmp/django_cache && chown -R www-data:www-data /var/tmp/django_cache
  mkdir -p /opt/openoni/log

  # Update Apache config
  cp /opt/openoni/docker/apache/openoni.conf /etc/apache2/sites-available/openoni.conf

  # Set Apache log level from APACHE_LOG_LEVEL in .env file
  sed -i "s/!LOGLEVEL!/$APACHE_LOG_LEVEL/g" /etc/apache2/sites-available/openoni.conf

  # Enable updated Apache config
  a2ensite openoni

  # Get static files ready for Apache to serve
  cd /opt/openoni
  source ENV/bin/activate

  echo "-------" >&2
  echo "Running collectstatic" >&2
  /opt/openoni/manage.py collectstatic --noinput
  # Sass processor needs write access to STATIC_ROOT
  chown -R www-data:www-data /opt/openoni/static/compiled

  # Remove any pre-existing PID file which prevents Apache from starting thus
  # causing the container to close immediately after.
  #
  # See: https://github.com/docker-library/php/pull/59
  rm -f /var/run/apache2/apache2.pid
}

run_apache() {
  echo "ONI setup successful; starting Apache"
  source /etc/apache2/envvars
  exec apache2 -D FOREGROUND
}
