#!/bin/bash

set -e

# Ensure buildx builder exists for multi-platform builds
if ! docker buildx inspect multiplatform-builder > /dev/null 2>&1; then
  echo "Creating buildx builder for multi-platform builds..."
  docker buildx create --name multiplatform-builder --use
else
  docker buildx use multiplatform-builder
fi

# Define platforms
PLATFORMS="linux/arm64,linux/amd64"

if [[ ($* == --publish) ]];
then
  echo "Building multi-platform image for: $PLATFORMS"

  # Build for multiple platforms and push to registry
  docker buildx build \
    --platform $PLATFORMS \
    --tag antriver/php-fpm-nginx:latest \
    --push \
    .

  # Pull the image back to get version info (will pull the platform matching current architecture)
  docker pull antriver/php-fpm-nginx:latest

  # Generate a version string based on the PHP and Nginx versions.
  # e.g. php8.3.10-nginx1.22.1
  VERSION=`docker run -it antriver/php-fpm-nginx:latest bash -c "echo -n php\\\`php -r 'echo PHP_VERSION;'\\\`-nginx\\\`nginx -v 2>&1 | cut -d'/' -f2\\\`"`

  echo "Tagging as version $VERSION"

  # Build again with version tag for all platforms
  docker buildx build \
    --platform $PLATFORMS \
    --tag antriver/php-fpm-nginx:latest \
    --tag antriver/php-fpm-nginx:$VERSION \
    --push \
    .

  echo "Published antriver/php-fpm-nginx:latest and antriver/php-fpm-nginx:$VERSION for $PLATFORMS"
else
  echo "Building for local use (current platform only)..."

  # Build for current platform and load into local docker
  docker buildx build \
    --tag antriver/php-fpm-nginx:latest \
    --load \
    .

  # Generate a version string based on the PHP and Nginx versions.
  VERSION=`docker run -it antriver/php-fpm-nginx:latest bash -c "echo -n php\\\`php -r 'echo PHP_VERSION;'\\\`-nginx\\\`nginx -v 2>&1 | cut -d'/' -f2\\\`"`

  echo "Tagging as version $VERSION"

  # Tag the latest image with the correct version.
  docker image tag antriver/php-fpm-nginx:latest antriver/php-fpm-nginx:$VERSION

  echo "Built antriver/php-fpm-nginx:latest and antriver/php-fpm-nginx:$VERSION for local platform"
  echo "To build and publish for multiple platforms ($PLATFORMS), run: $0 --publish"
fi
