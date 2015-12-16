#!/bin/bash
# COPYRIGHT_NOTICE_1

# Make a version.sml file with brief version and build information for the flrc.
# usage: make-version.sh version outfile
# where:
#   version is the flrc version string
#   outfile is the filename to put the output into

version=$1
out=$2
prefix=$3
# Windows hostname outputs a final carriage return
build="`date '+%F %R'` on `hostname | tr -d '\r'`"

rm -f $out

echo "structure Version =" >> $out
echo "struct" >> $out
echo "  val flrcVersion = \"$version\"" >> $out
echo "  val build = \"$build\"" >> $out
echo "  val prefix = Path.fromString \"$prefix\"" >> $out
echo "end" >> $out
