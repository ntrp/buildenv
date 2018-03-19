#!/usr/bin/env bash

# curl and pipe it to /bin/bash to initialize a docker build environment and
# start a build:
# curl -o- https://raw.githubusercontent.com/mimacom/buildenv/master/init-docker-buildenv.sh | /bin/bash
#
# Use this script e.g. on a build server, while you are in a repo with the
# following structure:
#
# .
# ├── docker
# │   ├── Dockerfile    =>  Describes your build environment.
# │   └── build.sh      =>  Describes your build tasks which will run inside
#                           your build environment (Docker container).
#
# This script will check if there's already a built Docker image on Dockerhub.
# This is done by creating a sha256 hash of the Dockerfile. Then, the following
# image will be pulled: mimacom/buildenv:<hash>
#
# If the hash/tag does not exist, this script will build a Docker image using
# the Dockerfile and push it to Dockerhub for future usage. Make sure you have
# valid credentials in ~/.docker/config.json. Populate them with "docker login"
# if necessary.
#
# Finally, when Docker image is ready and available locally, a temporary
# container is created, and the build.sh file is run inside the container.
# Output will be sent to stdout of the Docker host for proper log files
# on your build server.
# After build.sh is finished, the container is stopped and removed.
#
# Note: The image itself will remain on the host. You may want to set up
#       a cleanup job.

function build_and_push() {
  echo "init-docker-buildenv: building image"

  # build docker image
  docker build -t "${docker_image}" ./docker
  
  if [ $? -eq 0 ]
  then
    echo "init-docker-buildenv: pushing buildenv to dockerhub"
    
    # and pull it to dockerhub
    docker push "${docker_image}"
    return $?
  else
    return 1
  fi
}

function hash() {
  platform=`uname | tr '[:upper:]' '[:lower:]'`
  
  if [ "${platform}" == "darwin" ]
  then
    shasum -a 256 $1 | awk '{ print $1 }'
  else
    sha256sum $1 | awk '{ print $1 }'
  fi
}

function is_bambooagent() { hostname | egrep --quiet 'mima-bambooagent-[0-9]+.mimacom.local'; }


docker_base=`egrep "^[ \t]*FROM" docker/Dockerfile | awk '{ print $2 }'`
docker_repo="mimacom/buildenv"
docker_tag=`hash docker/Dockerfile`
docker_image="${docker_repo}:${docker_tag}"
  

# pull base image
docker pull "${docker_base}" | grep newer

# when newer base image was downloaded
if [ $? -eq 0 ]
then
  echo "init-docker-buildenv: newer base image downloaded"
  
  # also build and push a new buildenv
  build_and_push
  
# otherwise, check if buildenv stored locally or on github is up to date
else
  echo "init-docker-buildenv: try to pull buildenv image from dockerhub"
  docker pull "${docker_image}"

  # if docker image does not exist
  if [ $? -ne 0 ]
  then
    build_and_push
  fi
fi

# fetch bamboo vars
export -p | grep "bamboo_" > ./docker/envvars.sh

# write start script
cat<<EOF > ./docker/start.sh
#!/usr/bin/env bash
set -o errexit

source ~/.bashrc
cd /build
source ./docker/envvars.sh
source ./docker/build.sh
EOF

chmod +x ./docker/start.sh

# run build inside container
echo "init-docker-buildenv: starting job in a new docker container"

if is_bambooagent
then
  # create directories if they do not exist
  mkdir -p ~bambooagent/.m2
  mkdir -p ~bambooagent/.gradle
  docker run --privileged --rm -i \
     -u 5000 \
     -v `pwd`:/build/ \
     -v ~bambooagent/.m2/:/home/user/.m2/ \
     -v ~bambooagent/.gradle/:/home/user/.gradle/ \
     "${docker_image}" "/build/docker/start.sh"
else
  user_host=`whoami`
  # create directories if they do not exist
  mkdir -p ~/.m2
  mkdir -p ~/.gradle
  #sudo chown -R 5000:5000 ~/.m2
  docker run --privileged --rm -i \
     -u 5000 \
     -v `pwd`:/build/ \
     -v ~/.m2/:/home/user/.m2/ \
     -v ~/.gradle/:/home/user/.gradle/ \
     "${docker_image}" "/build/docker/start.sh"
  #sudo chown -R "${user_host}:${user_host}" ~/.m2
  rm ./docker/envvars.sh
  rm ./docker/start.sh
fi
