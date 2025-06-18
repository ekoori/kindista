#!/usr/bin/env bash
set -e

# Directory where Quicklisp will be installed
QL_DIR="${QL_DIR:-$HOME/quicklisp}"

# Install system packages
sudo apt-get update
sudo apt-get install -y sbcl git curl nginx imagemagick

# Install Quicklisp for SBCL
if [ ! -d "$QL_DIR" ]; then
  curl -L https://beta.quicklisp.org/quicklisp.lisp -o /tmp/quicklisp.lisp
  sbcl --non-interactive \
       --load /tmp/quicklisp.lisp \
       --eval "(quicklisp-quickstart:install :path \"$QL_DIR\")" \
       --eval "(ql:add-to-init-file)" \
       --quit
  rm /tmp/quicklisp.lisp
fi

# Download Kindista Lisp dependencies
sbcl --non-interactive \
     --eval "(ql:quickload :kindista)" \
     --quit

echo "Kindista dependencies installed."
