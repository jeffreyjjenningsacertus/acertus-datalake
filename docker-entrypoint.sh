#!/bin/bash
#
# Copyright 2019 StreamSets Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

# Check whether there is a passwd entry for the container UID
myuid=$(id -u)
mygid=$(id -g)
# turn off -e for getent because it will return error code in anonymous uid case
set +e
uidentry=$(getent passwd $myuid)
set -e

# If there is no passwd entry for the container UID, attempt to create one
if [ -z "$uidentry" ] ; then
    if [ -w /etc/passwd ] ; then
        echo "$myuid:x:$myuid:$mygid:anonymous uid:$SPARK_HOME:/bin/false" >> /etc/passwd
        echo "${TRANSFORMER_USER:-transformer}:x:$myuid:0:${TRANSFORMER_USER:-transformer} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "Container ENTRYPOINT failed to add passwd entry for anonymous UID"
    fi
fi

SPARK_K8S_CMD="$1"
case "$SPARK_K8S_CMD" in
    driver | driver-py | driver-r | executor)
      shift 1
      ;;
    *)
      ;;
esac

SPARK_CLASSPATH="$SPARK_CLASSPATH:${SPARK_HOME}/jars/*"
env | grep SPARK_JAVA_OPT_ | sort -t_ -k4 -n | sed 's/[^=]*=\(.*\)/\1/g' > /tmp/java_opts.txt
readarray -t SPARK_EXECUTOR_JAVA_OPTS < /tmp/java_opts.txt

if [ -n "$SPARK_EXTRA_CLASSPATH" ]; then
  SPARK_CLASSPATH="$SPARK_CLASSPATH:$SPARK_EXTRA_CLASSPATH"
fi

if [ -n "$PYSPARK_FILES" ]; then
    PYTHONPATH="$PYTHONPATH:$PYSPARK_FILES"
fi

PYSPARK_ARGS=""
if [ -n "$PYSPARK_APP_ARGS" ]; then
    PYSPARK_ARGS="$PYSPARK_APP_ARGS"
fi

R_ARGS=""
if [ -n "$R_APP_ARGS" ]; then
    R_ARGS="$R_APP_ARGS"
fi

if [ "$PYSPARK_MAJOR_PYTHON_VERSION" == "2" ]; then
    pyv="$(python -V 2>&1)"
    export PYTHON_VERSION="${pyv:7}"
    export PYSPARK_PYTHON="python"
    export PYSPARK_DRIVER_PYTHON="python"
elif [ "$PYSPARK_MAJOR_PYTHON_VERSION" == "3" ]; then
    pyv3="$(python3 -V 2>&1)"
    export PYTHON_VERSION="${pyv3:7}"
    export PYSPARK_PYTHON="python3"
    export PYSPARK_DRIVER_PYTHON="python3"
fi


# We translate environment variables to transformer.properties and rewrite them.
set_transformer_conf() {
  if [ $# -ne 2 ]; then
    echo "set_conf requires two arguments: <key> <value>"
    exit 1
  fi

  if [ -z "$TRANSFORMER_CONF" ]; then
    echo "TRANSFORMER_CONF is not set."
    exit 1
  fi

   echo "set_transformer_conf called: $1: $2"

  sed -i 's|^#\?\('"$1"'=\).*|\1'"$2"'|' "${TRANSFORMER_CONF}/transformer.properties"
}

# We translate environment variables to transformer.properties and rewrite them.
set_dpm_conf() {
  if [ $# -ne 2 ]; then
    echo "set_conf requires two arguments: <key> <value>"
    exit 1
  fi

  if [ -z "$TRANSFORMER_CONF" ]; then
    echo "TRANSFORMER_CONF is not set."
    exit 1
  fi

  echo "set_dpm_conf called: $1: $2"

  sed -i 's|^#\?\('"$1"'=\).*|\1'"$2"'|' "${TRANSFORMER_CONF}/dpm.properties"
}

case "$SPARK_K8S_CMD" in
  driver)
    CMD=(
      "$SPARK_HOME/bin/spark-submit"
      --conf "spark.driver.bindAddress=$SPARK_DRIVER_BIND_ADDRESS"
      --deploy-mode client
      "$@"
    )
    ;;
  driver-py)
    CMD=(
      "$SPARK_HOME/bin/spark-submit"
      --conf "spark.driver.bindAddress=$SPARK_DRIVER_BIND_ADDRESS"
      --deploy-mode client
      "$@" $PYSPARK_PRIMARY $PYSPARK_ARGS
    )
    ;;
    driver-r)
    CMD=(
      "$SPARK_HOME/bin/spark-submit"
      --conf "spark.driver.bindAddress=$SPARK_DRIVER_BIND_ADDRESS"
      --deploy-mode client
      "$@" $R_PRIMARY $R_ARGS
    )
    ;;
  executor)
    CMD=(
      ${JAVA_HOME}/bin/java
      "${SPARK_EXECUTOR_JAVA_OPTS[@]}"
      -Xms$SPARK_EXECUTOR_MEMORY
      -Xmx$SPARK_EXECUTOR_MEMORY
      -cp "$SPARK_CLASSPATH:$SPARK_DIST_CLASSPATH"
      org.apache.spark.executor.CoarseGrainedExecutorBackend
      --driver-url $SPARK_DRIVER_URL
      --executor-id $SPARK_EXECUTOR_ID
      --cores $SPARK_EXECUTOR_CORES
      --app-id $SPARK_APPLICATION_ID
      --hostname $SPARK_EXECUTOR_POD_IP
    )
    ;;

  *)
    # Copy file from /ssl/truststore.jks to etc folder if it exists
    if [[ -f "/ssl/truststore.jks" ]]; then
      cp /ssl/truststore.jks "${TRANSFORMER_CONF}"/
    fi
    for e in $(env); do
      key=${e%%=*}
      value=${e#*=}
      if [[ $key == transformer_conf_* ]]; then
        key=$(echo "${key#*transformer_conf_}" | sed 's|_|.|g')
        set_transformer_conf "$key" "$value"
      elif [[ $key == dpm_conf_* ]]; then
        key=$(echo "${key#*dpm_conf_}" | sed 's|_|.|g')
        set_dpm_conf "$key" "$value"
      elif [[ $key == transformer_id ]]; then
        echo "${value}" > "${TRANSFORMER_DATA}"/sdc.id
      elif [[ $key == transformer_token_string ]]; then
        echo "${value}" > "${TRANSFORMER_CONF}"/application-token.txt
      fi
    done
    CMD=(
      ${TRANSFORMER_DIST}/bin/streamsets
      "transformer"
      "-exec"
    )
    ;;
esac

# Execute the container CMD under tini for better hygiene
exec /sbin/tini -s -- "${CMD[@]}"
