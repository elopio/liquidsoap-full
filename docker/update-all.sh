#!/bin/sh -e

for image in debian:testing debian:stable ubuntu:eoan ubuntu:focal; do
  docker system prune -f;
  docker pull $image;
  ./update-deps.sh $image;
  ./update-ci.sh $image;
done;
