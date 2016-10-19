#!/bin/sh
#
# set -x

# this is the tinderbox script:
# it runs "emerge -u" for each package and parses the output, that's all

# barrier start
# this prevents the start of a broken copy of ourself - see end of file too
#
(

# strip away escape sequences
#
function stresc() {
  # remove colour ESC sequences, ^[[K and carriage return
  # do not use perl -ne 's/\e\[?.*?[\@-~]//g; print' due to : https://bugs.gentoo.org/show_bug.cgi?id=564998#c6
  #
  perl -MTerm::ANSIColor=colorstrip -nle '$_ = colorstrip($_); s/\e\[K//g; s/\r/\n/g; print'
}


# send out an email with $1 as the subject and $2 as the body
#
function Mail() {
  subject=$(echo "$1" | cut -c1-200)
  ( [[ -e $2 ]] && stresc < $2 || date ) | mail -s "$subject    @ $name" $mailto &>> /tmp/mail.log
}


# clean up and exit
#
function Finish()  {
  Mail "FINISHED: $*" $log

  eix-update -q
  rm -f /tmp/STOP

  exit 0
}


# arbitraily choose a java engine
#
function SwitchJDK()  {
  old=$(eselect java-vm show system 2>/dev/null | tail -n 1 | xargs)
  if [[ -n "$old" ]]; then
    new=$(eselect java-vm list 2>/dev/null | grep -E 'oracle-jdk-[[:digit:]]|icedtea[-bin]*-[[:digit:]]' | grep -v 'system-vm' | awk ' { print $2 } ' | sort --random-sort | head -n 1)
    if [[ -n "$new" ]]; then
      if [[ "$new" != "$old" ]]; then
        eselect java-vm set system $new &> $log
        if [[ $? -ne 0 ]]; then
          Mail "$FUNCNAME failed for $old -> $new" $log
        fi
      fi
    fi
  fi
}


# for a package do evaluate here if it is worth to call emerge
#
function GetNextTask() {
  #   update @system once a day, if no special task is scheduled
  #
  ts=/tmp/timestamp.system
  if [[ ! -f $ts ]]; then
    touch $ts
  else
    let "diff = $(date +%s) - $(date +%s -r $ts)"
    if [[ $diff -gt 86400 ]]; then
      grep -q -E "^(STOP|INFO|%|@)" $pks
      if [[ $? -ne 0 ]]; then
        task="@system"
        SwitchJDK
        return
      fi
    fi
  fi

  # splice last line of the package list $pks into $task
  #
  while :;
  do
    task=$(tail -n 1 $pks)
    sed -i -e '$d' $pks

    if [[ -n "$(echo $task | grep '^INFO')" ]]; then
      Mail "$task"

    elif [[ -n "$(echo $task | grep '^STOP')" ]]; then
      Finish "$task"

    elif  [[ -z "$task" ]]; then
      if [[ -s $pks ]]; then
        continue  # package list itself isn't empty, just this line
      fi

      # we reached the end of the lifetime
      #
      /usr/bin/pfl &>/dev/null
      n=$(qlist --installed | wc -l)
      Finish "$n packages emerged"

    elif [[ "$(echo $task | cut -c1)" = '%' ]]; then
      return  # a complete command line

    elif [[ "$(echo $task | cut -c1)" = '@' ]]; then
      return  # a package set

    else
      # ignore known trouble makers
      #
      echo "$task" | grep -q -f /tmp/tb/data/IGNORE_PACKAGES
      if [[ $? -eq 0 ]]; then
        continue
      fi

      # make some pre-checks here
      # emerge takes too much time before it gives up

      # skip if $task is masked, keyworded or an invalid string
      #
      best_visible=$(portageq best_visible / $task 2>/dev/null)
      if [[ $? -ne 0 || -z "$best_visible" ]]; then
        continue
      fi

      # skip if $task is already installed or would be downgraded
      #
      installed=$(portageq best_version / $task)
      if [[ -n "$installed" ]]; then
        qatom --compare $installed $best_visible | grep -q -e ' == ' -e ' > '
        if [[ $? -eq 0 ]]; then
          continue
        fi
      fi

      # well, emerge $task
      #
      return
    fi
  done
}


# gather together what we do need for a bugzilla report
#
function CollectIssueFiles() {
  ehist=/var/tmp/portage/emerge-history.txt
  cmd="qlop --nocolor --gauge --human --list --unlist"

  echo "# This file contains the emerge history got with:" > $ehist
  echo "# $cmd" >> $ehist
  echo "#"      >> $ehist
  $cmd          >> $ehist

  # misc build logs
  #
  cflog=$(grep -m 1 -A 2 'Please attach the following file when seeking support:'    $bak | grep "config\.log"     | cut -f2 -d' ')
  if [[ -z "$cflog" ]]; then
    cflog=$(ls -1 /var/tmp/portage/$failed/work/*/config.log 2>/dev/null)
  fi
  apout=$(grep -m 1 -A 2 'Include in your bugreport the contents of'                 $bak | grep "\.out"           | cut -f5 -d' ')
  cmlog=$(grep -m 1 -A 2 'Configuring incomplete, errors occurred'                   $bak | grep "CMake.*\.log"    | cut -f2 -d'"')
  cmerr=$(grep -m 1      'CMake Error: Parse error in cache file'                    $bak | sed  "s/txt./txt/"     | cut -f8 -d' ')
  sandb=$(grep -m 1 -A 1 'ACCESS VIOLATION SUMMARY'                                  $bak | grep "sandbox.*\.log"  | cut -f2 -d'"')
  oracl=$(grep -m 1 -A 1 '# An error report file with more information is saved as:' $bak | grep "\.log"           | cut -f2 -d' ')
  envir=$(grep -m 1      'The ebuild environment file is located at'                 $bak                          | cut -f2 -d"'")
  salso=$(grep -m 1 -A 2 ' See also'                                                 $bak | grep "\.log"           | awk '{ print $1 }' )

  # strip away escape sequences, echo is used to expand those variables containing place holders
  #
  for f in $(echo $ehist $failedlog $cflog $apout $cmlog $cmerr $sandb $oracl $envir $salso)
  do
    if [[ -f $f ]]; then
      stresc < $f > $issuedir/files/$(basename $f)
    fi
  done

  cp $bak $issuedir

  # compress files bigger than 1 MiByte
  #
  for f in $issuedir/files/* $issuedir/_*
  do
    c=$(wc -c < $f)
    if [[ $c -gt 1000000 ]]; then
      bzip2 $f
    fi
  done
  chmod a+r $issuedir/files/*
}


# create an email containing convenient links + info ready for being picked up by copy+paste
#
function CompileInfoMail() {
  keyword="stable"
  grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
  if [[ $? -eq 0 ]]; then
    keyword="unstable"
  fi

  cat << EOF >> $issuedir/emerge-info.txt
  -----------------------------------------------------------------

  This is an $keyword amd64 chroot image (named $name) at a hardened host acting as a tinderbox.

  -----------------------------------------------------------------
  USE flags ...

  ... in make.conf:
USE="$(source /etc/portage/make.conf; echo -n '  '; echo $USE)"

  ... in /etc/portage/package.use/*:
$(grep -v -e '^#' -e '^$' /etc/portage/package.use/* | cut -f2- -d':' | sed 's/^/  /g')

  entries in /etc/portage/package.unmask/*:
$(grep -v -e '^#' -e '^$' /etc/portage/package.unmask/* | cut -f2- -d':' | sed 's/^/  /g')
  -----------------------------------------------------------------

gcc-config -l:
$(gcc-config -l        2>&1         && echo)
llvm-config --version:
$(llvm-config --version 2>&1        && echo)
$(eselect java-vm list 2>/dev/null  && echo)
$(eselect python  list 2>&1         && echo)
$(eselect ruby    list 2>/dev/null  && echo)
  -----------------------------------------------------------------

EOF

  # no --verbose, output is bigger than the 16 KB limit of b.g.o.
  #
  emerge --info --verbose=n $short >> $issuedir/emerge-info.txt

  # get bug report assignee and cc, GLEP 67 rules
  #
  m=$(equery meta -m $failed | grep '@' | xargs)
  if [[ -z "$m" ]]; then
    m="maintainer-needed@gentoo.org"
  fi

  # if we found more than 1 maintainer, then take the 1st as the assignee
  #
  echo "$m" | grep -q ' '
  if [[ $? -eq 0 ]]; then
    echo "$m" | cut -f1  -d ' ' > $issuedir/assignee
    echo "$m" | cut -f2- -d ' ' | tr ' ' ',' > $issuedir/cc
  else
    echo "$m" > $issuedir/assignee
    touch $issuedir/cc
  fi

  # try to find a descriptive title and the most meaningful lines of the issue
  #
  touch $issuedir/{issue,title}

  if [[ -n "$(grep -m 1 ' * Detected file collision(s):' $bak)" ]]; then
    # we provide package name+version althought this gives more noise in our mail inbox
    #
    s=$(grep -m 1 -A 2 'Press Ctrl-C to Stop' $bak | grep '::' | tr ':' ' ' | cut -f3 -d' ')
    # inform the maintainers of the already installed package too
    #
    cc=$(equery meta -m $s | grep '@' | grep -v "$(cat $issuedir/assignee)" | xargs)
    # sort -u guarantees, that the file $issuedir/cc is completely read in before it will be overwritten
    #
    (cat $issuedir/cc; echo $cc) | tr ',' ' '| xargs -n 1 | sort -u | xargs | tr ' ' ',' > $issuedir/cc

    grep -m 1 -A 20 ' * Detected file collision(s):' $bak | grep -B 15 ' * Package .* NOT' > $issuedir/issue
    echo "file collision with $s" > $issuedir/title

  elif [[ -f $sandb ]]; then

    donotmaskit=1
    echo "=$failed nosandbox" >> /etc/portage/package.env/nosandbox

    p="$(grep -m1 ^A: $sandb)"
    echo "$p" | grep -q "A: /root/"
    if [[ $? -eq 0 ]]; then
      # handle XDG sandbox issues in a special way
      #
      cat <<EOF > $issuedir/issue
This issue is forced at the tinderbox by making:

$(grep '^export XDG_' /tmp/job.sh)

pls see bug #567192 too

EOF
      echo "sandbox issue (XDG_xxx_DIR related)" > $issuedir/title
    else
      # other sandbox issues
      #
      echo "sandbox issue $p" > $issuedir/title
    fi
    head -n 20 $sandb >> $issuedir/issue

  else
    # to catch the real culprit we've loop over all patterns exactly in their order
    # therefore we can't use "grep -f CATCH_ISSUES"
    #
    cat /tmp/tb/data/CATCH_ISSUES |\
    while read c
    do
      grep -m 1 -B 2 -A 3 "$c" $bak > $issuedir/issue
      if [[ -s $issuedir/issue ]]; then
        head -n 3 < $issuedir/issue | tail -n 1 > $issuedir/title
        break
      fi
    done

    # this gcc-6 issue is forced by us, masking all affected packages
    # would prevent tinderboxing of a lot of deps
    #
    # next time this package will be build with default c++ flags
    #
    grep -q '\[\-Werror=terminate\]' $issuedir/title
    if [[ $? -eq 0 ]]; then
      echo "=$failed cxx" >> /etc/portage/package.env/cxx
      donotmaskit=1
    fi
  fi

  # shrink too long error messages like "/a/b/c.h:23: error 1"
  #
  sed -i -e 's#/[^ ]*\(/[^/:]*:\)#/...\1#g' $issuedir/title

  # kick off hex addresses and such stuff to improve search results in b.g.o.
  #
  sed -i -e 's/0x[0-9a-f]*/<snip>/g' -e 's/: line [0-9]*:/:line <snip>:/g' $issuedir/title

  # guess from the title if there's a bug tracker for this issue
  # the BLOCKER file must follow this syntax:
  #
  #   # comment
  #   <bug id>
  #   <pattern>
  #   ...
  #
  # if <pattern> is defined more than once then the first entry will make it
  #
  block=$(
    grep -v -e '^#' -e '^[1-9].*$' /tmp/tb/data/BLOCKER |\
    while read line
    do
      grep -q -E "$line" $issuedir/title
      if [[ $? -eq 0 ]]; then
        echo -n "-b "
        grep -m 1 -B 1 "$line" /tmp/tb/data/BLOCKER | head -n 1 # no grep -E here !
        break
      fi
    done
  )

  # the email contains:
  # - the issue, package version and maintainer
  # - a bgo.sh command line ready for copy+paste
  # - bugzilla search result/s
  #
  cp $issuedir/issue $issuedir/body

  cat << EOF >> $issuedir/body

--
versions: $(eshowkw -a amd64 $short | grep -A 100 '^-' | grep -v '^-' | awk '{ if ($3 == "+") { print $1 } else { print $3$1 } }' | xargs)
assignee: $(cat $issuedir/assignee)
cc:       $(cat $issuedir/cc)
--

EOF

  # search if $issue is already filed or return a list of similar records
  #
  search_string=$(cut -f3- -d' ' $issuedir/title | sed "s/['‘’\"]/ /g")
  id=$(bugz -q --columns 400 search --status OPEN,RESOLVED --show-status $short "$search_string" | tail -n 1 | grep '^[[:digit:]]* ' | tee -a $issuedir/body | cut -f1 -d ' ')
  if [[ -n "$id" ]]; then
    cat << EOF >> $issuedir/body
  https://bugs.gentoo.org/show_bug.cgi?id=$id

  ~/tb/bin/bgo.sh -d $name/$issuedir -a $id

EOF
  else
    echo -e "  ~/tb/bin/bgo.sh -d $name/$issuedir $block\n" >> $issuedir/body

    h="https://bugs.gentoo.org/buglist.cgi?query_format=advanced&short_desc_type=allwordssubstr"
    g="stabilize|Bump| keyword| bump"

    echo "  OPEN:     $h&resolution=---&short_desc=$short"      >> $issuedir/body
    bugz --columns 400 -q search --show-status      $short 2>&1 | grep -v -i -E "$g" | tail -n 20 | tac >> $issuedir/body

    echo "" >> $issuedir/body
    echo "  RESOLVED: $h&bug_status=RESOLVED&short_desc=$short" >> $issuedir/body
    bugz --columns 400 -q search --status RESOLVED  $short 2>&1 | grep -v -i -E "$g" | tail -n 20 | tac >> $issuedir/body
  fi

  # attach now collected files
  #
  for f in $issuedir/emerge-info.txt $issuedir/files/* $issuedir/_*
  do
    uuencode $f $(basename $f) >> $issuedir/body
  done

  # prefix the Subject with package name + version
  #
  sed -i -e "s#^#$failed : #" $issuedir/title

  # b.g.o. limits "Summary" to 255 chars
  #
  if [[ $(wc -c < $issuedir/title) -gt 255 ]]; then
    truncate -s 255 $issuedir/title
  fi

  chmod    777  $issuedir/{,files}
  chmod -R a+rw $issuedir/
}


# emerge failed for some reason, parse the output
#
function GotAnIssue()  {
  # prefix our log backup file with an "_" to distinguish it from portage's log files
  #
  bak=/var/log/portage/_emerge_$(date +%Y%m%d-%H%M%S).log
  stresc < $log > $bak

  # put all successfully emerged dependencies of $task into the world file
  # otherwise we'd need "--deep" (https://bugs.gentoo.org/show_bug.cgi?id=563482)
  #
  line=$(tac /var/log/emerge.log | grep -m 1 -E ':  === |: Started emerge on: ')
  echo "$line" | grep -q ':  === ('
  if [[ $? -eq 0 ]]; then
    echo "$line" | grep -q ':  === (1 of '
    if [[ $? -ne 0 ]]; then
      emerge --depclean --pretend --verbose=n 2>/dev/null | grep "^All selected packages: " | cut -f2- -d':' | xargs emerge --noreplace &>/dev/null
    fi
  fi

  # bail out if an OOM or related did happen
  #
  fatal=$(grep -f /tmp/tb/data/FATAL_ISSUES $bak)
  if [[ -n "$fatal" ]]; then
    Finish "FATAL: $fatal"
  fi

  # our current shared repository solution is (rarely) racy
  #
  grep -q -e 'AssertionError: ebuild not found for' -e 'portage.exception.FileNotFound:' $bak
  if [[ $? -eq 0 ]]; then
    Mail "notice: race of repository sync and emerge dep tree calculation" $bak
    echo $task >> $pks
    return
  fi

  # do not mask those package b/c the root cause might be fixed/circumvent during the lifetime of the image
  #
  grep -q -f /tmp/tb/data/IGNORE_ISSUES $bak
  if [[ $? -eq 0 ]]; then
    return
  fi

  # guess the failed package from its log file name
  #
  failedlog=$(grep -m 1 "The complete build log is located at" $bak | cut -f2 -d"'")
  if [[ -z "$failedlog" ]]; then
    failedlog=$(grep -m 1 -A 1 "', Log file:" $bak | tail -n 1 | cut -f2 -d"'")
    if [[ -z "$failedlog" ]]; then
      failedlog=$(grep -m 1 "^>>>  '" $bak | cut -f2 -d"'")
    fi
  fi

  if [[ -n "$failedlog" ]]; then
    failed=$(basename $failedlog | cut -f1-2 -d':' | tr ':' '/')
  else
    failed="$(cd /var/tmp/portage; ls -1d */* 2>/dev/null)"
    # well, go the opposite way and guess the log file name from the package name
    #
    if [[ -z "$failedlog" ]]; then
      failedlog=$(ls -1t /var/log/portage/$(echo "$failed" | tr '/' ':'):????????-??????.log 2>/dev/null | head -n 1)
    fi
  fi

  # after this point we expect to work on an issue of a known package name
  #
  if [[ -z "$failed" ]]; then
    Mail "warn: \$failed is empty for task: $task" $bak
    return
  fi

  #the version less package name is used for a broader bugzilla search
  #
  short=$(qatom $failed | cut -f1-2 -d' ' | tr ' ' '/')
  if [[ -z "$short" ]]; then
    Mail "warn: \$short is empty for failed: $failed" $bak
    return
  fi

  # have a copy of all related files in $issuedir
  #
  issuedir=/tmp/issues/$(date +%Y%m%d-%H%M%S)_$(echo $failed | tr '/' '_')
  mkdir -p $issuedir/files
  donotmaskit=0

  CollectIssueFiles
  CompileInfoMail

  # special handling for Perl upgrade issue: https://bugs.gentoo.org/show_bug.cgi?id=596664
  #
  grep -q -e 'perl module is required for intltool' -e "Can't locate .* in @INC" $bak
  if [[ $? -eq 0 ]]; then
    (
    cd /
    tar -cjpf $issuedir/var.db.pkg.tbz2       var/db/pkg
    tar -cjpf $issuedir/var.lib.portage.tbz2  var/lib/portage
    tar -cjpf $issuedir/etc.portage.tbz2      etc/portage
    )
    Mail "notice: auto-fixing Perl upgrade issue for task $task" $bak
    echo -e "$task\n%perl-cleaner --all" >> $pks
    return
  fi

  if [[ $donotmaskit -eq 1 ]]; then
    # retry it with special package.env settings
    #
    echo "$task" >> $pks
  else
    # mask this particular package version at this image
    #
    grep -q "^=$failed$" /etc/portage/package.mask/self
    if [[ $? -ne 0 ]]; then
      echo "=$failed" >> /etc/portage/package.mask/self
    fi
  fi

  # send an email if the issue was not yet reported -or- not yet catched
  #
  grep -F -q -f $issuedir/title /tmp/tb/data/ALREADY_CATCHED
  if [[ $? -eq 0 ]]; then
    if [[ -z "$id" ]]; then
      Mail "ISSUE $(cat $issuedir/title)" $issuedir/body
    fi
  else
    cat $issuedir/title >> /tmp/tb/data/ALREADY_CATCHED
    Mail "${id:-ISSUE} $(cat $issuedir/title)" $issuedir/body
  fi
}


# *compiled* kernel modules are needed by some packages
#
function BuildKernel()  {
  (
    cd /usr/src/linux     &&\
    make defconfig        &&\
    make modules_prepare  &&\
    make                  &&\
    make modules_install  &&\
    make install
  ) &> $log
  rc=$?

  if [[ $rc -ne 0 ]]; then
    Finish "ERROR: $FUNCNAME failed (rc=$rc)"
  fi
}


# switch to latest GCC, see: https://wiki.gentoo.org/wiki/Upgrading_GCC
#
function SwitchGCC() {
  latest=$(gcc-config --list-profiles --nocolor | cut -f3 -d' ' | grep 'x86_64-pc-linux-gnu-.*[0-9]$' | tail -n 1)
  gcc-config --list-profiles --nocolor | grep -q "$latest \*$"
  if [[ $? -ne 0 ]]; then
    verold=$(gcc -v 2>&1 | tail -n 1 | cut -f1-3 -d' ')
    gcc-config --nocolor $latest &> $log
    . /etc/profile
    vernew=$(gcc -v 2>&1 | tail -n 1 | cut -f1-3 -d' ')

    majold=$(echo $verold | cut -f3 -d ' ' | cut -c1)
    majnew=$(echo $vernew | cut -f3 -d ' ' | cut -c1)

    # switch the system to the new gcc
    #
    if [[ "$majold" != "$majnew" ]]; then
      # rebuild kernel sources to avoid an error like: "cc1: error: incompatible gcc/plugin versions"
      #
      if [[ -e /usr/src/linux/.config ]]; then
        (cd /usr/src/linux && make clean &>>$log)
        BuildKernel &>> $log
      fi

      revdep-rebuild --ignore --library libstdc++.so.6 -- --exclude gcc &>> $log
      if [[ $? -ne 0 ]]; then
        GotAnIssue
        Finish "FAILED: $FUNCNAME from $verold to $vernew rebuild failed"
      fi

      # clean up old GCC to double-ensure that packages is build against the new headers/libs
      #
      fix_libtool_files.sh $verold
      emerge --unmerge =sys-devel/gcc-${verold}*

      # per request of Soap this is forced for the new gcc-6
      # if a package fails therefore then we will add a package specific entry to package.env
      #
      if [[ "$keyword" = "unstable" ]]; then
        sed -i -e 's/^CXXFLAGS="/CXXFLAGS="-Werror=terminate /' /etc/portage/make.conf
      fi
    fi
  fi
}


# eselect the latest *emerged* kernel and schedule a build if necessary
#
function SelectNewKernel() {
  last=$(ls -1dt /usr/src/linux-* | head -n 1 | cut -f4 -d'/')
  link=$(eselect kernel show | tail -n 1 | sed -e 's/ //g' | cut -f4 -d'/')

  if [[ "$last" != "$link" ]]; then
    eselect kernel set $last &>> $log
    if [[ ! -f /usr/src/linux/.config ]]; then
      echo "%BuildKernel" >> $pks
    fi
  fi
}


# do *schedule* emerge operation here, do not run emerge
# append actions in their reverse order to the package list
#
function PostEmerge() {
  # do not auto-update these config files
  #
  rm -f /etc/ssmtp/._cfg????_ssmtp.conf
  rm -f /etc/portage/._cfg????_make.conf

  etc-update --automode -5 &>/dev/null
  env-update &>/dev/null
  . /etc/profile

  grep -q "IMPORTANT: config file '/etc/locale.gen' needs updating." $log
  if [[ $? -eq 0 ]]; then
    locale-gen &>/dev/null
  fi

  grep -q ">>> Installing .* sys-kernel/.*-sources" $log
  if [[ $? -eq 0 ]]; then
    SelectNewKernel
  fi

  grep -q "Use emerge @preserved-rebuild to rebuild packages using these libraries" $log
  if [[ $? -eq 0 ]]; then
    n=$(tac /var/log/emerge.log | grep -F -m 20 '*** emerge' | grep -c "emerge .* @preserved-rebuild")
    if [[ $n -gt 4 ]]; then
      # even if the root cause of the @preserved-rebuild issue was solved the test above would still be true
      # therefore we need a marker which tells us to ignore the test
      # this marker is the truncastion of the file of the @preserved-rebuild history
      #
      f=/tmp/timestamp.preserved-rebuild
      if [[ -s $f ]]; then
        chmod a+w $f
        Finish "${n}x @preserved-rebuild, run 'truncate -s 0 $name/$f' before next start"
      fi
    fi
    echo "@preserved-rebuild" >> $pks
  fi

  grep -q -e "Please, run 'haskell-updater'" -e "ghc-pkg check: 'checking for other broken packages:'" $log
  if [[ $? -eq 0 ]]; then
    echo "%haskell-updater" >> $pks
  fi

  grep -q ">>> Installing .* sys-devel/gcc-[1-9]" $log
  if [[ $? -eq 0 ]]; then
    echo "%SwitchGCC" >> $pks
  fi

  grep -q 'Please run "revdep-pax" after installation.' $log
  if [[ $? -eq 0 ]]; then
    echo "%revdep-pax" >> $pks
  fi

  grep -q ">>> Installing .* dev-lang/perl-[1-9]" $log
  if [[ $? -eq 0 ]]; then
    echo "%perl-cleaner --all" >> $pks
  fi
}


# this is the heart of the tinderbox, the rest is just output parsing
#
function EmergeTask() {
  if [[ "$task" = "@preserved-rebuild" ]]; then
    emerge --backtrack=30 $task &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue
    fi

    echo "$(date) $failed" >> /tmp/timestamp.preserved-rebuild
    PostEmerge

  elif [[ "$task" = "@system" ]]; then
    emerge --deep --update --changed-use --with-bdeps=y $task &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue
      echo "$(date) $failed" >> /tmp/timestamp.system
    else
      echo "$(date) ok" >> /tmp/timestamp.system
      # activate 32/64bit library builds if @system upgrade succeeded
      #
      grep -q '^ABI_X86=' /etc/portage/make.conf
      if [[ $? -ne 0 ]]; then
        eselect profile show | grep -q 'no-multilib'
        if [[ $? -ne 0 ]]; then
          echo 'ABI_X86="32 64"' >> /etc/portage/make.conf
          echo "@system" >> $pks
        fi
      fi
    fi

    PostEmerge
    /usr/bin/pfl &>/dev/null

  else
    # run either a command line (prefixed with "%") or just emerge the given package
    #
    if [[ "$(echo $task | cut -c1)" = '%' ]]; then
      cmd=$(echo "$task" | cut -c2-)
    else
      cmd="emerge --update $task"
    fi

    $cmd &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue
    fi
    PostEmerge
  fi
}


#############################################################################
#
#       main
#
mailto="tinderbox@zwiebeltoralf.de"
log=/tmp/task.log                   # holds always output of "emerge ... "
pks=/tmp/packages                   # the pre-filled package list file

export GCC_COLORS=""                # suppress colour output of gcc-4.9 and above

# eg.: amd64-gnome-unstable_20150913-104240
#
name=$(grep "^PORTAGE_ELOG_MAILFROM=" /etc/portage/make.conf | cut -f2 -d '"' | cut -f1 -d ' ')

# https://bugs.gentoo.org/show_bug.cgi?id=567192
#
export XDG_DESKTOP_DIR="/root/Desktop"
export XDG_DOCUMENTS_DIR="/root/Documents"
export XDG_DOWNLOAD_DIR="/root/Downloads"
export XDG_MUSIC_DIR="/root/Music"
export XDG_PICTURES_DIR="/root/Pictures"
export XDG_PUBLICSHARE_DIR="/root/Public"
export XDG_TEMPLATES_DIR="/root/Templates"
export XDG_VIDEOS_DIR="/root/Videos"

export XDG_RUNTIME_DIR="/root/run"
export XDG_CONFIG_HOME="/root/config"
export XDG_CACHE_HOME="/root/cache"
export XDG_DATA_HOME="/root/share"

while :;
do
  # restart ourself if origin was edited
  #
  diff -q /tmp/tb/bin/job.sh /tmp/job.sh 1>/dev/null
  if [[ $? -ne 0 ]]; then
    exit 125
  fi

  date > $log
  if [[ -f /tmp/STOP ]]; then
    Finish "catched stop signal"
  fi

  # clean up from a previous emerge operation
  # this isn't made by portage b/c we had to collect build files first
  #
  rm -rf /var/tmp/portage/*
  GetNextTask
  EmergeTask
done

Finish "Bummer! We should never reach this line !"

# barrier end (see start of this file too)
#
)
