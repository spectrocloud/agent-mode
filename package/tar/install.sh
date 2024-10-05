#!/bin/bash
set -e
# set -x # Uncomment for debugging

unpack() {
    TAR_FILE=$1
    tar -xvf $TAR_FILE -C /
}

unpack $1
