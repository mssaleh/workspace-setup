ARG BASE=ubuntu:26.04
FROM ${BASE}
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo ca-certificates \
 && useradd --create-home --uid 1001 --shell /bin/bash qa \
 && printf 'qa ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/qa \
 && chmod 0440 /etc/sudoers.d/qa
USER qa
WORKDIR /home/qa
ENV HOME=/home/qa USER=qa LOGNAME=qa SHELL=/bin/bash
