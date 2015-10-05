#!/bin/bash
### HELP section
dp_help_message="This command has not any help
[redhat] publish type
"
source $DP_HOME/dp_help.sh $*
### END HELP section

if [ "$DEBUG_PIPELINE" == "TRUE" ]; then
   set -x
else
   set +x
fi

source $DP_HOME/profiles/publish/default/dp_publish.sh
source $DP_HOME/profiles/package/redhat/createrepo.sh


YUM_CONF_FILE=/var/tmp/yum-dependencies.conf

TMP_DEPENCENCIES_FILE=/var/tmp/dependencies-$$.tmp

function get_3party_builder_repo(){
   if [ "$ALL_RPMS_IN_RPM_HOME" == "" ]; then
      echo $(dirname $(dirname $(default_repo_dir)))/builders
   else
      echo $ALL_RPMS_IN_RPM_HOME/builders
   fi
}

function get_repo_dir(){
   local rpm_file=$1
   local rpm_name=$(echo $rpm_file|cut -d':' -f1| tr -d ' '|tr -d '\t')
   #is this rpm_file for this so version?
   local so_versions=$(echo $rpm_file|awk -F ":" '{print $2}')
   if [[ "$so_versions" != "" ]]; then
      source $DP_HOME/tools/versions/dp_version.sh
      local os_release=$(get_os_release)
      if [[ "$so_versions" != *$os_release* ]]; then
         return 2
      fi
   fi
   
   local arch=$(echo $rpm_name|cut -d'.' -f$(expr $(echo $rpm_name|cut -d'.' -f1- --output-delimiter=$'\n'|wc -l) - 1) 2>/dev/null)
   local target_dir=""
   if [ "$ALL_RPMS_IN_RPM_HOME" == "" ]; then
      echo $(default_repo_dir)/$arch
   else
      echo $ALL_RPMS_IN_RPM_HOME/$arch
   fi
}

function enable_new_repo(){
    local thirdparty_repo=$(get_3party_builder_repo)
    if ! [ -d $thirdparty_repo/repodata ]; then
       createrepo $thirdparty_repo
    fi
    echo "
[main]
keepcache=0
debuglevel=2
logfile=/var/log/yum.log
exactarch=1
obsoletes=1
gpgcheck=1
plugins=1
installonly_limit=3
[3party-builder]
baseurl=file://$thirdparty_repo
gpgcheck=0
name=Packages for 3party in builders
enabled=1
metadata_expire=0
" >$YUM_CONF_FILE

    echo "
[dependencies]
baseurl=file://$(dirname $1)/$(uname -i)
gpgcheck=0
name=Packages dependencies for $(uname -i)
enabled=1
metadata_expire=0
[dependencies-noarch]
baseurl=file://$(dirname $1)/noarch
gpgcheck=0
name=Package dependencies for noarch
enabled=1
metada_expire=0
"  >>$YUM_CONF_FILE
  }

function extract_dependencies(){
  local rpm_files=$1
  local line
  rm -rf $TMP_DEPENCENCIES_FILE
  while read line; do
    if [[ -f "$line" ]]; then
       rpm -qp --requires $line|grep -v ^"config(" >>$TMP_DEPENCENCIES_FILE
    else
       echo $line|tr -d ' '|tr -d '\t'|grep -v "^#"|grep -v "^$"|grep -v ":">>$TMP_DEPENCENCIES_FILE
       echo $line|sed s:".*/":"":g|tr -d ' '|tr -d '\t'|grep -v "^#"|grep -v "^$"|grep ":$(get_os_release)$"|cut -d':' -f1>>$TMP_DEPENCENCIES_FILE
    fi
  done < $rpm_files
}
function are_there_any_new_dependency(){
  local target_repo=$1
  local dependencies_file=$(dirname $target_repo)/.dependencies
  touch $dependencies_file
  cat $dependencies_file>>$TMP_DEPENCENCIES_FILE
  cat $TMP_DEPENCENCIES_FILE|sort|uniq -i > $TMP_DEPENCENCIES_FILE.new
  rm -rf $TMP_DEPENCENCIES_FILE
  if [[ "$(diff $TMP_DEPENCENCIES_FILE.new $dependencies_file)" != "" ]]; then
    mv $TMP_DEPENCENCIES_FILE.new $dependencies_file
    return 0
  else
    # there aren't any new dependency
    _log "[INFO] There aren´t any new dependency"
    rm -rf $TMP_DEPENCENCIES_FILE.new
    return 1
  fi
}

function get_dependencies(){
   _log "[INFO] Started: Get dependencies"
   local rpm_files=$1
   local target_repo=""
   local target_repo_dir=""
   extract_dependencies $rpm_files
   IFS=$'\n'
   # rpm_files examples:
   # Each line have two fields, separated by ':'
   # rpm_name-->Name of rpm
   # os_releases: --> System Operatings releases supported by this rpm. If this field is
   # empty then this rpm supports all so releases 
   # <rpm_name>[-version].>x86_64|noarch>.rpm[:el5,:el6]
   local rpm_dependencies=$(cat $rpm_files|sed s:".*/":"":g|tr -d ' '|tr -d '\t'|grep -v "^#"|grep -v "^$"|grep -v ":")
   rpm_dependencies="$rpm_dependencies $(cat $rpm_files|sed s:".*/":"":g|tr -d ' '|tr -d '\t'|grep -v "^#"|grep -v "^$"|grep ":$(get_os_release)$"|cut -d':' -f1)"
   if [ "$rpm_dependencies" == "" ]; then
      _log "[WARNING] There aren't any dependency in $rpm_files"
      return 0
   fi
   local first_dependency=$(echo $rpm_dependencies|awk '{print $1}')
   target_repo="$(get_repo_dir $first_dependency)"
   local rpm_dependency
   # Are all dependencies ok?
   for rpm_dependency in $rpm_dependencies;do
      target_repo="$(get_repo_dir $rpm_dependency)"
      local error_code=$?
      if [ $error_code == "1" ]; then
         _log "[ERROR] The format of dependency[$rpm_dependency] defined in \
thirdparty-rpms.txt is wrong.The format must be: \
name-[version].[x86_64|noarch].rpm[:el5,:el6]"
          return 1
      fi
   done;
   enable_new_repo $target_repo
   if [ "$ALL_RPMS_IN_RPM_HOME" != "" ]; then
      target_repo_dir=$(dirname $target_repo)/3party
      initiative_rpm_dirs=$(dirname $target_repo)
   else
      local rpm_home_initiative=$(dirname $(dirname $target_repo))
      target_repo_dir=$(dirname $(dirname $target_repo))/3party
      initiative_rpm_dirs="$rpm_home_initiative/initiative/noarch $rpm_home_initiative/initiative/$(uname -i)"
   fi
   unset IFS
   are_there_any_new_dependency $target_repo_dir || return 0
   createrepo $target_repo_dir
   local rpm_names=$(echo $rpm_dependencies|sed s:"\.rpm$":"":g|sed s:"\.rpm ":" ":g)
   _log "[INFO] Downloading dependencies for $rpm_names"
   install_root_dir=/var/tmp/install-root
   rm -Rf "/var/tmp/yum-$(id -un)-*" $install_root_dir
   mkdir -p $install_root_dir
   eval yumdownloader -t -c $YUM_CONF_FILE --installroot $install_root_dir --destdir $target_repo_dir --resolve $rpm_names
   # Remove initiative rpms stored in 3party repo
   _log "[INFO] Remove initiative rpms stored in 3party"
   IFS=" "
   for initiative_dir in $initiative_rpm_dirs; do
      if [[ -d "$initiative_dir" ]]; then
         pushd . >/dev/null
         cd $initiative_dir
         IFS=$'\n'
         for file in $(find -maxdepth 1 -type f -name "*.rpm"); do
            rm -f $target_repo_dir/$(basename $file)
         done;
         unset IFS
         popd >/dev/null
      fi
   done;
   _log "[INFO] Remove 3party deprecated rpm versions"
   dp_remove_rpm_deprecated_versions.sh $target_repo_dir
   createrepo $target_repo_dir
   _log "[INFO] End: Get dependencies"
}

#Extracts the name of an artifact.
function get_artifact_name(){
   local artifact_file=$1
   rpm -qp --queryformat "[%{NAME}]" $artifact_file
}

# Publish rpm in the correct repository
function publish_rpms(){
   local rpm_files=$1
   local archs_file=${rpm_files}.arch
   publish_artifacts $rpm_files
   if [ -f $archs_file ]; then
      local target_repo="$(get_repo_dir $(head -1 $rpm_files))"
      if [ $? != 0 ]; then
         _log "[ERROR] The name of rpm must be name[-version].[$(uname -i)|noarch].rpm"
         exit 1
      fi
      local repo_dir_without_arch=$(dirname $target_repo)
      for architecture in $(cat $archs_file|sort|uniq -i); do
         _log "[INFO] Updating rpm repo stored in $repo_dir_without_arch/$architecture"
         createrepo $repo_dir_without_arch/$architecture
         if [[ "$?" != "0" ]]; then
            exitError "Unable to update repository[$repo_dir_without_arch/$architecture]. Review permissions" 1
         fi
      done;
   fi
   get_dependencies $rpm_files
   local error_code=$?
   if [ $error_code != 0 ]; then
      return $error_code
   fi
   publish_3party_rpm_dependencies
}

# Execute and action after rpm is published
function post_publish(){
   if [ "$POST_PUBLISH_RPM_SCRIPT" != "" ]; then
      _log "[INFO] Execution post publish rpm script"
      $POST_PUBLISH_RPM_SCRIPT $*
   fi
}

# Search a thirdparty-rpms.txt with external dependencies (mysql-server,
# rabbitmq-server ...)
function publish_3party_rpm_dependencies(){
   if [ -f "thirdparty-rpms.txt" ]; then
      _log "[INFO] Publishing third party rpms"
      get_dependencies $PWD/thirdparty-rpms.txt
      return $?
   fi
   return 0
}

function execute(){
   yum clean all
   publish "*.rpm"
   local error_code=$?
   if [ $error_code != 0 ]; then
      return $error_code
   fi
}

function main(){
   local dp_publish_invoke=$0
   # If it's invoke by source ... the $0=-bash
   [ "${dp_publish_invoke:0:1}" != "-" ] \
               && [ "$(basename $0)" == "dp_publish.sh" ] \
               && execute $* \
               && post_publish $* \
               && exit $?
}

if [ "$DEBUG_PIPELINE" == "TRUE" ]; then
   main --debug $*
else
   main $*
fi
