#!/bin/bash

# Usage: ./build.sh [php-version] [--publish]
# Examples:
#   ./build.sh
#   ./build.sh 8.4.13
#   ./build.sh 8.3 --publish
#
# Without a PHP version the image is built from the newest php:fpm and is also tagged as latest.

# Exit on error.
set -e

IMAGE=antriver/php-fpm-nginx
PLATFORMS="linux/arm64,linux/amd64"

usage() {
  echo "❌ Usage: $0 [php-version] [--publish]"
  echo "   Example: $0 8.4.13 or $0 8.3 --publish"
}

# Checks there are stored Docker Hub credentials without prompting, because docker login would start an interactive login.
# It only checks they exist, so expired credentials still pass.
has_docker_hub_login() {
  local config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  local store
  store=$(sed -n 's/.*"credsStore": *"\([^"]*\)".*/\1/p' "$config" 2>/dev/null)
  if [ -n "$store" ]; then
    echo "https://index.docker.io/v1/" | "docker-credential-$store" get > /dev/null 2>&1
  else
    grep -q '"https://index.docker.io/v1/"' "$config" 2>/dev/null
  fi
}

VERSION=""
PUBLISH=false
for ARG in "$@"; do
  case $ARG in
    --publish)
      PUBLISH=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [ -n "$VERSION" ]; then
        usage
        exit 1
      fi
      VERSION=$ARG
      ;;
  esac
done

# Validate the version looks like 8, 8.4 or 8.4.13
if [ -n "$VERSION" ] && [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "❌ Error: PHP version must look like 8, 8.4 or 8.4.13"
  usage
  exit 1
fi

# Check the login now rather than letting the push fail after a full build.
if [ "$PUBLISH" = true ] && ! has_docker_hub_login; then
  echo "❌ Not logged in to Docker Hub. Run docker login (or sign in to Docker Desktop) and try again."
  exit 1
fi

if [ -n "$VERSION" ]; then
  PHP_IMAGE_TAG="$VERSION-fpm"
else
  PHP_IMAGE_TAG="fpm"
fi

# Ensure buildx builder exists for multi-platform builds
if ! docker buildx inspect multiplatform-builder > /dev/null 2>&1; then
  echo "🔧 Creating buildx builder for multi-platform builds..."
  docker buildx create --name multiplatform-builder --use
else
  docker buildx use multiplatform-builder
fi

# Build for the current platform first so the versions can be read from the image.
# No cache, so Nginx and Debian packages are always fresh. The publish build then reuses these layers for this platform,
# so the published image contains the same versions as its tag.
LOCAL_TAG="$IMAGE:build-$PHP_IMAGE_TAG"
echo "🎯 Building from php:$PHP_IMAGE_TAG for the local platform..."
docker buildx build \
  --no-cache \
  --build-arg PHP_IMAGE_TAG="$PHP_IMAGE_TAG" \
  --tag "$LOCAL_TAG" \
  --load \
  .

echo "🔍 Reading PHP and Nginx versions..."
PHP_VERSION=$(docker run --rm "$LOCAL_TAG" php -r 'echo PHP_VERSION;')
NGINX_VERSION=$(docker run --rm "$LOCAL_TAG" sh -c 'nginx -v 2>&1')
NGINX_VERSION=${NGINX_VERSION##*/}

# Check that the reported PHP version matches the requested version.
if [ -n "$VERSION" ] && [[ "$PHP_VERSION" != "$VERSION" && "$PHP_VERSION" != "$VERSION".* ]]; then
  echo "❌ Reported PHP version $PHP_VERSION does not match requested version $VERSION"
  exit 1
fi

# e.g. php8.4.13-nginx1.28.0
TAGS=("$IMAGE:php$PHP_VERSION-nginx$NGINX_VERSION")
if [ -z "$VERSION" ]; then
  TAGS+=("$IMAGE:latest")
fi

for TAG in "${TAGS[@]}"; do
  docker image tag "$LOCAL_TAG" "$TAG"
done
docker image rm "$LOCAL_TAG" > /dev/null

echo "🎉 Built ${TAGS[*]} for the local platform"

if [ "$PUBLISH" = true ]; then
  echo "🚀 Building for $PLATFORMS and publishing to Docker Hub..."

  TAG_ARGS=()
  for TAG in "${TAGS[@]}"; do
    TAG_ARGS+=(--tag "$TAG")
  done

  docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg PHP_IMAGE_TAG="$PHP_IMAGE_TAG" \
    "${TAG_ARGS[@]}" \
    --push \
    .

  echo "✅ Published ${TAGS[*]} for $PLATFORMS"
else
  echo "   To build and publish for $PLATFORMS, run: $0 ${VERSION:+$VERSION }--publish"
fi
