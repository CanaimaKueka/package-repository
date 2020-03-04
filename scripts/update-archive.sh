#!/bin/bash

BASE="$(dirname $(dirname $(realpath ${0})))"
LOCKEXISTS="TRUE"

while [ "${LOCKEXISTS}" == "TRUE" ]; do
  if [ ! -e "${BASE}/db/lockfile" ]; then
    LOCKEXISTS="FALSE"
  fi
done

MIRROR="http://http.us.debian.org"
ERRORKEY="is already registered with different checksums"

DISTFILE="${BASE}/conf/distributions"
UPDATESFILE="${BASE}/conf/updates"
DEBIANEXCLUDESFILE="${BASE}/conf/excludes/debian"

LOGDIR="/var/log/archives"
UPDATESLOGFILE="${LOGDIR}/updates.log"
INCLUDESLOGFILE="${LOGDIR}/includes.log"

DATE="$( date +%Y%m%d )"
TIME="$( date +%H%M%S )"
DISTS="$( cat "${DISTFILE}" | grep "Codename:" | awk -F':' '{print $2}' | xargs )"
UPDATES="$( cat "${UPDATESFILE}" | grep "Name:" | awk '{print $2}' )"
COMPONENTS="$( cat "${UPDATESFILE}" | grep "^Components:" | grep "contrib" | awk -F':' '{print $2}' | head -1 | sed 's/>/ /g' | xargs -n 1 | sort -u | xargs )"

if [ -z "$( ls -1 ${BASE}/conf/incoming-dir )" ]; then
  CURRENTINCOMINGPKGS=""
else
  CURRENTINCOMINGPKGS="$( ls -1 ${BASE}/conf/incoming-dir/*.deb | awk -F'_' '{print $1}' | xargs )"
fi

DEBIANEXCLUDES="$( cat "${DEBIANEXCLUDESFILE}" | awk '{print $1}' | xargs ) ${CURRENTINCOMINGPKGS}"
printf '%s purge\n' $( echo "${DEBIANEXCLUDES}" | xargs -n 1 | sort -u | xargs ) > "${DEBIANEXCLUDESFILE}"

echo "Processing incoming folder ..." >> "${UPDATESLOGFILE}"
reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 processincoming incoming 1>>"${UPDATESLOGFILE}" 2>&1
rm -rf ${BASE}/conf/incoming-dir/*

for DIST in ${DISTS}; do
  CONTINUE="TRUE"
  echo "Start processing of distribution: ${DIST} " >> "${UPDATESLOGFILE}"
  if [ -d "${BASE}/dists/${DIST}" ]; then
    while [ "${CONTINUE}" == "TRUE" ]; do
      if reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 update ${DIST} 1>>"${UPDATESLOGFILE}" 2>&1; then
        echo "Update completed for distribution: ${DIST}" >> "${UPDATESLOGFILE}"
        CONTINUE="FALSE"
      else
        BADCHECKSUMPKG="$( cat "${UPDATESLOGFILE}" | grep "${ERRORKEY}" | awk -F'"' '{print $2}' | awk -F'/' '{print $4}' )"
        echo "There was an error processing distribution: ${DIST}" >> "${UPDATESLOGFILE}"

        if [ -n "${BADCHECKSUMPKG}" ]; then
          echo "This package ${ERRORKEY}: ${BADCHECKSUMPKG}" >> "${UPDATESLOGFILE}"
          for DISTRO in ${DISTS}; do
            echo "Removing package: ${BADCHECKSUMPKG}, from distribution: ${DISTRO}" >> "${UPDATESLOGFILE}"
            reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 removesrc ${DISTRO} ${BADCHECKSUMPKG} 1>>"${UPDATESLOGFILE}" 2>&1
            reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 remove ${DISTRO} ${BADCHECKSUMPKG} 1>>"${UPDATESLOGFILE}" 2>&1
          done
        else
          CONTINUE="FALSE"
        fi
      fi
    done
  fi
  echo "Creating symlinks ..." >> "${UPDATESLOGFILE}"
  reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 --delete createsymlinks ${DIST} 1>>"${UPDATESLOGFILE}" 2>&1
  echo "Exporting changes ..." >> "${UPDATESLOGFILE}"
  reprepro -VVV --basedir ${BASE} --logdir ${LOGDIR} --noskipold --waitforlock 20 export ${DIST} 1>>"${UPDATESLOGFILE}" 2>&1
done


echo "Copying translations ..." >> "${UPDATESLOGFILE}"
for DIST in ${DISTS}; do
  for COMPONENT in ${COMPONENTS}; do
    echo "Removing ${BASE}/${DIST}/${COMPONENT}/i18n" >> "${UPDATESLOGFILE}"
    rm -rvf "${BASE}/${DIST}/${COMPONENT}/i18n" >> "${UPDATESLOGFILE}"
    echo "Getting i18n folder from ${MIRROR}/debian/dists/sid/${COMPONENT}/i18n/" >> "${UPDATESLOGFILE}"
    umask o+r,u+rw,g+rw
    wget -P${BASE}/dists/${DIST}/${COMPONENT} -nH --cut-dirs=4 -r --reject "index.html*" --no-parent ${MIRROR}/debian/dists/sid/${COMPONENT}/i18n/  >> "${UPDATESLOGFILE}"
  done
done

echo "Copying debian installer ..." >> "${UPDATESLOGFILE}"
for DIST in ${DISTS}; do
  ARCHS="$( ls -1 "${BASE}/dists/${DIST}/main/" | grep "binary-" | sed 's/binary-//g' )"
  for ARCH in ${ARCHS}; do
    echo "Removing ${BASE}/dists/${DIST}/main/installer-${ARCH}" >> "${UPDATESLOGFILE}"
    rm -rvf "${BASE}/dists/${DIST}/main/installer-${ARCH}" >> "${UPDATESLOGFILE}"
    echo "Getting installer-${ARCH} folder from ${MIRROR}/debian/dists/sid/main/installer-${ARCH}" >> "${UPDATESLOGFILE}"
    umask o+r,u+rw,g+rw
    wget -P${BASE}/dists/${DIST}/main -nH --cut-dirs=4 -r --reject "index.html*" --no-parent ${MIRROR}/debian/dists/sid/main/installer-${ARCH}/  >> "${UPDATESLOGFILE}"
    find ${BASE}/dists/${DIST}/main/installer-${ARCH}/ -mindepth 1 ! -regex "^${BASE}/dists/${DIST}/main/installer-${ARCH}/current\(/.*\)?" -delete
  done
done

mv "${UPDATESLOGFILE}" "${LOGDIR}/updates-${DATE}${TIME}.log"
gzip "${LOGDIR}/updates-${DATE}${TIME}.log"

mv "${INCLUDESLOGFILE}" "${LOGDIR}/includes-${DATE}${TIME}.log"
gzip "${LOGDIR}/includes-${DATE}${TIME}.log"

find ${LOGDIR} -type f -name "*.log" -mindepth 1 -mtime +5 -delete

exit 0
