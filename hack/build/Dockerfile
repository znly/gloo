FROM golang:1.13.7

RUN apt-get update && \
    apt-get -y install wget unzip && \
    wget -q https://github.com/protocolbuffers/protobuf/releases/download/v3.6.1/protoc-3.6.1-linux-x86_64.zip && \
    unzip -q protoc-3.6.1-linux-x86_64.zip -d protoc && \
    mv protoc/include/* /usr/local/include/ &&  \
    mv protoc/bin/protoc /usr/local/bin/ && \
    rm protoc-3.6.1-linux-x86_64.zip && \
    rm -rf protoc

RUN apt-get -y update && \
    apt-get -y install \
        apt-transport-https \
        ca-certificates \
        curl \
        make \
        zip \
        unzip

ADD . /tmp/src

WORKDIR /tmp/src

RUN go mod download

RUN rm -rf /tmp/src


