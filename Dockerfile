# Base image
FROM adoptopenjdk/openjdk8:jdk8u192-b12-alpine

# Container arguments
ARG ARG_GLIBC_VERSION=2.31-r0
ARG ARG_HADOOP_VERSION=3.2.1
ARG ARG_SPARK_VERSION=2.4.5
ARG ARG_PY4J_VERSION=0.10.7
ARG ARG_TRANSFORMER_VERSION=3.13.0

# Container metadata
LABEL maintainer="jeffrey.jennings@acertusdelivers.com" \
      version="3.13.0" \
      description="StreamSets Transformer"

# Add tools required to set up Java and StreamSets Transformer on the image
# =========================================================================================================================
# Note echo 'hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4' >> /etc/nsswitch.conf, means the following:
# hosts: line specifies the order in which various name resolution services will be tried. The default is to:
# 1. Begin by checking the /etc/Hosts file. If that file provides an IP address for the host name in question, it is used.
# 2. Otherwise try mdns4_minimal, which will attempt to resolve the name via multicast DNS only if it ends with .local. If
# it does but no such mDNS host is located, mdns4_minimal will return NOTFOUND. The default name service switch response
# to NOTFOUND would be to try the next listed service, but the [NOTFOUND=return] entry overrides that and stops the search
# with the name unresolved.
# 3. Then try the specified DNS servers. This will happen more-or-less immediately if the name does not end in .local, or
# not at all if it does. If you remove the [NOTFOUND=return] entry, nsswitch would try to locate unresolved .local hosts
# via unicast DNS. This would generally be a bad thing , as it would send many such requests to Internet DNS servers that
# would never resolve them. Apparently, that happens a lot.
# 4. The final mdns4 entry indicates mDNS will be tried for names that don't end in .local if your specified DNS servers
# aren't able to resolve them.
# =========================================================================================================================
RUN apk add --update --no-cache bash \
                                binutils \
                                coreutils \
                                curl \
                                tini \
                                python3 \
                                wget \
                                krb5-libs \
                                krb5 \
                                libstdc++ \
                                libuuid \
                                sed \
                                grep \
                                openssh && echo 'hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4' >> /etc/nsswitch.conf

# Add the JRE has a dependency on glibc that isn't available as an installation pacckage on the official repository, so
# we need to get them from the Github repo maintained by Sash Gerrand
RUN cd /tmp && \
    wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub && \
    wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${ARG_GLIBC_VERSION}/glibc-${ARG_GLIBC_VERSION}.apk && \
    apk add glibc-${ARG_GLIBC_VERSION}.apk

# Add the required libraries to prevent the following error when trying to execute java on this running image:
# "java: error while loading shared libraries: libz.so.1: cannot open shared object file: No such file or directory"
RUN curl -Lso /tmp/libz.tar.xz https://www.archlinux.org/packages/core/x86_64/zlib/download && \
    mkdir -p /tmp/libz && \
    tar -xf /tmp/libz.tar.xz -C /tmp/libz && \
    cp /tmp/libz/usr/lib/libz.so.* /usr/glibc-compat/lib

# Java environment variables
ENV JAVA_HOME=/opt/java/openjdk \
    PATH=$PATH:$JAVA_HOME/bin

# Hadoop environment variables
ENV HADOOP_HOME=/usr/hadoop \
    HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop \
    PATH=$PATH:$HADOOP_HOME/bin

# Add Apache Hadoop to run locally, so Transformer Amazon S3 stage can use the s3a protocol
RUN cd /tmp && \
    wget https://downloads.apache.org/hadoop/common/hadoop-${ARG_HADOOP_VERSION}/hadoop-${ARG_HADOOP_VERSION}.tar.gz && \
    mkdir -p ${HADOOP_HOME} && \
    tar xf /tmp/hadoop-${ARG_HADOOP_VERSION}.tar.gz -C /usr && \
    mv /usr/hadoop-${ARG_HADOOP_VERSION}/* ${HADOOP_HOME} && \
    rm -rf ${HADOOP_HOME}/share/doc && \
    chown -R root:root ${HADOOP_HOME}
    
# Spark environment variables
ENV SPARK_HOME=/opt/spark \
    SPARK_DIST_CLASSPATH=/usr/hadoop/etc/hadoop:/usr/hadoop/share/hadoop/common/lib/*:/usr/hadoop/share/hadoop/common/*:/usr/hadoop/share/hadoop/hdfs:/usr/hadoop/share/hadoop/hdfs/lib/*:/usr/hadoop/share/hadoop/hdfs/*:/usr/hadoop/share/hadoop/mapreduce/lib/*:/usr/hadoop/share/hadoop/mapreduce/*:/usr/hadoop/share/hadoop/yarn:/usr/hadoop/share/hadoop/yarn/lib/*:/usr/hadoop/share/hadoop/yarn/* \
    PATH=$PATH:$SPARK_HOME/bin \
    PYSPARK_PYTHON=/usr/bin/python3 \
    PYSPARK_DRIVER_PYTHON=${PYSPARK_PYTHON} \
    PYTHONPATH=/opt/spark/python:/opt/spark/python/lib/py4j-${ARG_PY4J_VERSION}-src.zip \
    PYSPARK_ALLOW_INSECURE_GATEWAY=1

# Add Apache Spark to run locally
RUN cd /tmp && \
    wget http://www.us.apache.org/dist/spark/spark-${ARG_SPARK_VERSION}/spark-${ARG_SPARK_VERSION}-bin-without-hadoop.tgz && \
    mkdir -p ${SPARK_HOME} && \
    tar xf /tmp/spark-${ARG_SPARK_VERSION}-bin-without-hadoop.tgz -C /usr && \
    mv /usr/spark-${ARG_SPARK_VERSION}-bin-without-hadoop/* ${SPARK_HOME} && \
    chown -R root:root ${SPARK_HOME}

# Transformer environment variables
ENV TRANSFORMER_DIST=/opt/streamsets-transformer \
    TRANSFORMER_HOME=${TRANSFORMER_DIST} \
    TRANSFORMER_USER=transformer

# Create 'transformer' user group and 'transformer' user
RUN addgroup -S ${TRANSFORMER_USER} && \
    adduser -S ${TRANSFORMER_USER} -G ${TRANSFORMER_USER}

# Add StreamSets Transformer
RUN cd /tmp && \
    mkdir -p ${TRANSFORMER_DIST} && \
    wget https://archives.streamsets.com/transformer/${ARG_TRANSFORMER_VERSION}/tarball/streamsets-transformer-all-${ARG_TRANSFORMER_VERSION}.tgz && \
    tar xzf /tmp/streamsets-transformer-all-${ARG_TRANSFORMER_VERSION}.tgz -C /opt && \
    mv /opt/streamsets-transformer-${ARG_TRANSFORMER_VERSION}/* ${TRANSFORMER_DIST} && \
    chown -R ${TRANSFORMER_USER}:${TRANSFORMER_USER} ${TRANSFORMER_DIST}

# Transformer environment variables
# *** Note, had to repeat declaration of environment variable assignment due to Docker forgetting
# *** the previous assigned values.
ENV TRANSFORMER_CONF=/etc/transformer \
    TRANSFORMER_DATA=/data/transformer \
    TRANSFORMER_DIST=/opt/streamsets-transformer \
    TRANSFORMER_HOME=${TRANSFORMER_DIST} \
    TRANSFORMER_LOG=/logs/transformer \
    TRANSFORMER_RESOURCES=/resources/transformer \
    USER_LIBRARIES_DIR=/opt/streamsets-transformer-user-libs \
    STREAMSETS_LIBRARIES_EXTRA_DIR=/opt/streamsets-libs-extras \
    TRANSFORMER_USER=transformer \
    TRANSFORMER_UID=20169 \
    TRANSFORMER_GID=${TRANSFORMER_UID}

# Create the Transformer folders outside of the default Transformer base folder
RUN mkdir -p ${TRANSFORMER_CONF} \
	     ${TRANSFORMER_DATA} \
	     ${TRANSFORMER_LOG} \
	     ${TRANSFORMER_RESOURCES} \
	     ${USER_LIBRARIES_DIR} \
	     ${STREAMSETS_LIBRARIES_EXTRA_DIR}
	     
# Move configuration to standard folders
RUN mv ${TRANSFORMER_HOME}/etc/* ${TRANSFORMER_CONF}

# Add manual external libraries (Transformer stages)
RUN mkdir -p ${STREAMSETS_LIBRARIES_EXTRA_DIR}/streamsets-spark-jdbc-lib \
             ${STREAMSETS_LIBRARIES_EXTRA_DIR}/streamsets-spark-jdbc-lib/lib

# Copy the JDBC PostgreSQL driver to the subfolder where the driver should be located on the container
COPY postgresql-42.2.12.jar ${STREAMSETS_LIBRARIES_EXTRA_DIR}/streamsets-spark-jdbc-lib/lib

# Enable SSL/TLS
COPY ca.crt ${TRANSFORMER_CONF}
COPY ca.key ${TRANSFORMER_CONF}
COPY localhost.p12 ${TRANSFORMER_CONF}
COPY keystore-password.txt ${TRANSFORMER_CONF}
COPY truststore-password.txt ${TRANSFORMER_CONF}
COPY transformer.properties ${TRANSFORMER_CONF}
RUN cp ${JAVA_HOME}/jre/lib/security/cacerts ${TRANSFORMER_CONF}/truststore.jks
RUN keytool -import -file ${TRANSFORMER_CONF}/ca.crt -trustcacerts -noprompt -alias MyCorporateCA -storepass changeit -keystore ${TRANSFORMER_CONF}/truststore.jks

# Give ${TRANSFORMER_USER} user group/user to StreamSets Transformer application folders
RUN chown -R ${TRANSFORMER_USER}:${TRANSFORMER_USER} ${TRANSFORMER_CONF} \
                                                     ${TRANSFORMER_DATA} \
                                                     ${TRANSFORMER_DIST} \
                                                     ${TRANSFORMER_LOG} \
                                                     ${TRANSFORMER_RESOURCES} \
                                                     ${USER_LIBRARIES_DIR} \
                                                     ${STREAMSETS_LIBRARIES_EXTRA_DIR} \
                                                     ${STREAMSETS_LIBRARIES_EXTRA_DIR}/streamsets-spark-jdbc-lib \
                                                     ${STREAMSETS_LIBRARIES_EXTRA_DIR}/streamsets-spark-jdbc-lib/lib

# Add logging to stdout to make logs visible through `docker logs`.
RUN sed -i 's|INFO, streamsets|INFO, streamsets,stdout|' ${TRANSFORMER_CONF}/transformer-log4j.properties

# Volume mount points
VOLUME [${JAVA_HOME}]
VOLUME [${TRANSFORMER_CONF}]
VOLUME [${TRANSFORMER_DATA}]
VOLUME [${TRANSFORMER_HOME}]
VOLUME [${TRANSFORMER_LOG}]
VOLUME [${TRANSFORMER_RESOURCES}]
VOLUME [${STREAMSETS_LIBRARIES_EXTRA_DIR}]
VOLUME [${USER_LIBRARIES_DIR}]

# Port(s) the container is listening on
EXPOSE 19630/tcp

# Set the Bash prompt for the container
ENV PS1='[$(whoami)@$(hostname) $(pwd)] '

# Copy the docker-entrypoint.sh script into the root folder of the container
COPY docker-entrypoint.sh /

# Configure the container to run as an executable
ENTRYPOINT ["/docker-entrypoint.sh"]