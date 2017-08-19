#!/bin/sh
#
# set -x

# this is the tinderbox script itself
# main function: WorkOnTask()
# the remaining code just parses the output, that's all


# strip away escape sequences
# hint: colorstrip() doesn't modify its argument, it returns the result
#
function stresc() {
  perl -MTerm::ANSIColor=colorstrip -nle '
    $_ = colorstrip($_);
    s,\r,\n,g;
    s/\x00/<0x00>/g;
    s/\x1b\x28\x42//g;
    s/\x1b\x5b\x4b//g;
    print;
  '
}


# send an email, $1 (mandatory) is the subject, $2 (optional) contains the body
#
function Mail() {
  subject=$(echo "$1" | stresc | cut -c1-200 | tr '\n' ' ')
  ( [[ -f $2 ]] && stresc < $2 || echo "${2:-<no body>}" ) | timeout 120 mail -s "$subject    @ $name" $mailto &>> /tmp/mail.log
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$(date) mail failed with rc=$rc issuedir=$issuedir"
  fi
}


# clean up and exit
# $1: return code, $2: email Subject
#
function Finish()  {
  rc=$1

  # although stresc() is called in Mail() run it here too b/c $2 might contain quotes
  #
  subject=$(echo "$2" | stresc | cut -c1-200 | tr '\n' ' ')

  /usr/bin/pfl            &>/dev/null
  /usr/bin/eix-update -q  &>/dev/null

  if [[ $rc -eq 0 ]]; then
    Mail "Finish ok: $subject"
  else
    Mail "Finish NOT ok, rc=$rc: $subject" $log
  fi

  if [[ $rc -eq 0 ]]; then
    rm -f $tsk
  fi

  rm -f /tmp/STOP

  exit $rc
}


# helper of setNextTask()
# choose an arbitrary system java engine
#
function SwitchJDK()  {
  old=$(eselect java-vm show system 2>/dev/null | tail -n 1 | xargs)
  if [[ -n "$old" ]]; then
    new=$(
      eselect java-vm list 2>/dev/null |\
      grep -e ' oracle-jdk-[[:digit:]] ' -e ' icedtea[-bin]*-[[:digit:]] ' |\
      grep -v " icedtea-bin-[[:digit:]].*-x86 " |\
      grep -v ' system-vm' |\
      awk ' { print $2 } ' | sort --random-sort | head -n 1
    )
    if [[ -n "$new" && "$new" != "$old" ]]; then
      eselect java-vm set system $new 1>> $log
    fi
  fi
}


# copy content of last line of the package list into variable $task
#
function setNextTask() {
  # update @system and @world once a day, if no special task is scheduled
  # switch the java machine too by the way
  #
  if [[ -s $pks ]]; then
    ts=/tmp/@system.history
    if [[ ! -f $ts ]]; then
      touch $ts
    else
      let "diff = $(date +%s) - $(date +%s -r $ts)"
      if [[ $diff -gt 86400 ]]; then
        # do not care about "#" lines to schedule @system
        #
        grep -q -E -e "^(STOP|INFO|%|@)" $pks
        if [[ $? -eq 1 ]]; then
          task="@system"
          echo "@world" >> $pks
          SwitchJDK
          return
        fi
      fi
    fi
  fi

  while :;
  do
    if [[ ! -s $pks ]]; then
      n=$(qlist --installed | wc -l)
      Finish 0 "empty package list, $n packages emerged"
    fi

    task=$(tail -n 1 $pks)
    sed -i -e '$d' $pks

    if [[ -z "$task" ]]; then
      continue  # empty lines are allowed

    elif [[ "$task" =~ ^INFO ]]; then
      Mail "$task"

    elif [[ "$task" =~ ^STOP ]]; then
      Finish 0 "$task"

    elif [[ "$task" =~ ^# ]]; then
      continue  # comment

    elif [[ "$task" =~ ^= || "$task" =~ ^@ || "$task" =~ ^% ]]; then
      return  # work on a pinned version | package set | command

    else
      echo "$task" | grep -q -f /tmp/tb/data/IGNORE_PACKAGES
      if [[ $? -eq 0 ]]; then
        continue
      fi

      # skip if $task is masked, keyworded or an invalid string
      #
      best_visible=$(portageq best_visible / $task 2>/dev/null)
      if [[ $? -ne 0 || -z "$best_visible" ]]; then
        continue
      fi

      # skip if $task is installed and would be downgraded
      #
      installed=$(portageq best_version / $task)
      if [[ -n "$installed" ]]; then
        qatom --compare $installed $best_visible | grep -q -e ' == ' -e ' > '
        if [[ $? -eq 0 ]]; then
          continue
        fi
      fi

      # $task is valid
      #
      return
    fi
  done
}


# for ABI_X86="32 64" we have two ./work directories in /var/tmp/portage/<category>/<name>
#
function setWorkDir() {
  workdir=$(fgrep -m 1 " * Working directory: '" $bak | cut -f2 -d"'" -s)
  if [[ ! -d "$workdir" ]]; then
    workdir=$(fgrep -m 1 ">>> Source unpacked in " $bak | cut -f5 -d" " -s)
    if [[ ! -d "$workdir" ]]; then
      workdir=/var/tmp/portage/$failed/work/$(basename $failed)
      if [[ ! -d "$workdir" ]]; then
        workdir=""
      fi
    fi
  fi
}


# helper of GotAnIssue()
# gather together what's needed for the email and b.g.o.
#
function CollectIssueFiles() {
  mkdir -p $issuedir/files

  ehist=/var/tmp/portage/emerge-history.txt
  local cmd="qlop --nocolor --gauge --human --list --unlist"

  cat << EOF > $ehist
# This file contains the emerge history got with:
# $cmd
#
EOF
  $cmd >> $ehist

  # collect few more build files, strip away escape sequences
  # and compress files bigger than 1 MiByte
  #
  apout=$(grep -m 1 -A 2 'Include in your bugreport the contents of'                 $bak | grep "\.out"          | cut -f5 -d' ' -s)
  cmlog=$(grep -m 1 -A 2 'Configuring incomplete, errors occurred'                   $bak | grep "CMake.*\.log"   | cut -f2 -d'"' -s)
  cmerr=$(grep -m 1      'CMake Error: Parse error in cache file'                    $bak | sed  "s/txt./txt/"    | cut -f8 -d' ' -s)
  oracl=$(grep -m 1 -A 1 '# An error report file with more information is saved as:' $bak | grep "\.log"          | cut -f2 -d' ' -s)
  envir=$(grep -m 1      'The ebuild environment file is located at'                 $bak                         | cut -f2 -d"'" -s)
  salso=$(grep -m 1 -A 2 ' See also'                                                 $bak | grep "\.log"          | awk '{ print $1 }' )
  sandb=$(grep -m 1 -A 1 'ACCESS VIOLATION SUMMARY' $bak                                  | grep "sandbox.*\.log" | cut -f2 -d'"' -s)
  roslg=$(grep -m 1 -A 1 'Tests failed. When you file a bug, please attach the following file: ' $bak | grep "/LastTest\.log" | awk ' { print $2 } ')

  # quirk for failing dev-ros/* tests
  #
  grep -q 'ERROR: Unable to contact my own server at' $roslg && echo "TEST ISSUE " > $issuedir/bgo_result

  for f in $ehist $failedlog $sandb $apout $cmlog $cmerr $oracl $envir $salso $roslg
  do
    if [[ -f $f ]]; then
      stresc < $f > $issuedir/files/$(basename $f)
    fi
  done

  for f in $issuedir/files/* $issuedir/_*
  do
    if [[ $(wc -c < $f) -gt 500000 ]]; then
      bzip2 $f
    fi
  done

  if [[ -d "$workdir" ]]; then
    # catch all log file(s)
    #
    f=/tmp/files
    rm -f $f
    (cd "$workdir" && find ./ -name "*.log" > $f && [[ -s $f ]] && tar -cjpf $issuedir/files/logs.tbz2 $(cat $f) && rm $f)

    # provide the whole temp dir if it exists
    #
    (cd "$workdir"/../.. && [[ -d ./temp ]] && tar -cjpf $issuedir/files/temp.tbz2 --dereference --warning=no-file-ignored ./temp)
  fi

  (cd / && tar -cjpf $issuedir/files/etc.portage.tbz2 --dereference etc/portage)

  chmod a+r $issuedir/files/*
}


# get assignee and cc for the b.g.o. entry
#
function AddMailAddresses() {
  m=$(equery meta -m $short | grep '@' | xargs)

  if [[ -n "$m" ]]; then
    a=$(echo "$m" | cut -f1  -d' ')
    c=$(echo "$m" | cut -f2- -d' ' -s)

    echo "$a" > $issuedir/assignee
    if [[ -n "$c" ]]; then
      echo "$c" > $issuedir/cc
    fi
  else
    echo "maintainer-needed@gentoo.org" > $issuedir/assignee
  fi
}


# present this info in #comment0 at b.g.o.
#
function AddWhoamiToIssue() {
  cat << EOF >> $issuedir/issue

  -------------------------------------------------------------------

  This is an $keyword amd64 chroot image at a tinderbox (==build bot)
  name: $name

  -------------------------------------------------------------------

EOF
}


# attach given files to the email body
#
function AttachFilesToBody()  {
  for f in $*
  do
    echo >> $issuedir/body
    s=$( ls -l $f | awk ' { print $5 } ' )
    if [[ $s -gt 1048576 ]]; then
      echo " not attached b/c bigger than 1 MB: $f" >> $issuedir/body
    else
      uuencode $f $(basename $f) >> $issuedir/body
    fi
    echo >> $issuedir/body
  done
}


# this info helps to decide whether to file a bug eg. for a stable package
# despite the fact that the issue was already fixed in an unstable version
#
function AddMetainfoToBody() {
  cat << EOF >> $issuedir/body

--
versions: $(eshowkw -a amd64 $short | grep -A 100 '^-' | grep -v '^-' | awk '{ if ($3 == "+") { print $1 } else if ($3 == "o") { print "**"$1 } else { print $3$1 } }' | xargs)
assignee: $(cat $issuedir/assignee)
cc:       $(cat $issuedir/cc 2>/dev/null)
--

EOF
}


# get $PN from $P (strip away the version)
#
function pn2p() {
  echo $(qatom "$1" 2>/dev/null | cut -f1-2 -d' ' | tr ' ' '/')
}


# 777: permit every user to edit the files
#
function CreateIssueDir() {
  issuedir=/tmp/issues/$(date +%Y%m%d-%H%M%S)_$(echo $failed | tr '/' '_')
  mkdir -p $issuedir
  chmod 777 $issuedir
}


# helper of ClassifyIssue()
#
function foundCollisionIssue() {
  # provide package name+version althought this gives more noise in our inbox
  #
  s=$(grep -m 1 -A 2 'Press Ctrl-C to Stop' $bak | grep '::' | tr ':' ' ' | cut -f3 -d' ' -s)
  # inform the maintainers of the sibbling package too
  # strip away version + release b/c the repository might be updated in the mean while
  #
  cc=$(equery meta -m $(pn2p "$s") | grep '@' | grep -v "$(cat $issuedir/assignee)" | xargs)
  # sort -u guarantees, that the file $issuedir/cc is completely read in before it will be overwritten
  #
  (cat $issuedir/cc 2>/dev/null; echo $cc) | xargs -n 1 | sort -u | xargs > $issuedir/cc

  grep -m 1 -A 20 ' * Detected file collision(s):' $bak | grep -B 15 ' * Package .* NOT' > $issuedir/issue
  echo "file collision with $s" > $issuedir/title
}


# helper of ClassifyIssue()
#
function foundSandboxIssue() {
  echo "=$failed nosandbox" >> /etc/portage/package.env/nosandbox
  try_again=1

  p="$(grep -m1 ^A: $sandb)"
  echo "$p" | grep -q "A: /root/"
  if [[ $? -eq 0 ]]; then
    # handle XDG sandbox issues (forced by us, see end of this file) in a special way
    #
    cat << EOF > $issuedir/issue
This issue is forced at the tinderbox by making:

$(grep '^export XDG_' /tmp/job.sh)

pls see bug #567192 too

EOF
    echo "sandbox issue (XDG_xxx_DIR related)" > $issuedir/title
  else
    echo "sandbox issue" > $issuedir/title
  fi
  head -n 10 $sandb >> $issuedir/issue
}


# helper of ClassifyIssue()
#
function foundTestIssue() {
  grep -q -e "=$failed " /etc/portage/package.env/notest 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "=$failed notest" >> /etc/portage/package.env/notest
    try_again=1
  fi

  (
    cd "$workdir"
    # tar returns an error if it can't find a directory, therefore feed only existing dirs to it
    #
    dirs="$(ls -d ./tests ./regress ./t ./Testing ./testsuite.dir 2>/dev/null)"
    if [[ -n "$dirs" ]]; then
      tar -cjpf $issuedir/files/tests.tbz2 \
        --exclude='*.o' --exclude="*/dev/*" --exclude="*/proc/*" --exclude="*/sys/*" --exclude="*/run/*" \
        --dereference --one-file-system --warning=no-file-ignored \
        $dirs
      rc=$?

      if [[ $rc -ne 0 ]]; then
        rm $issuedir/files/tests.tbz2
        Mail "notice: tar failed with rc=$rc for '$failed' with dirs='$dirs'" $bak
      fi
    fi
  )
}


# get the issue
# get an descriptive title from the most meaningful lines of the issue
# if needed: change package.env/...  to re-try failed with defaults settings
#
function ClassifyIssue() {
  touch $issuedir/{issue,title}

  if [[ -n "$(grep -m 1 ' * Detected file collision(s):' $bak)" ]]; then
    foundCollisionIssue

  elif [[ -f $sandb ]]; then
    foundSandboxIssue

  else
    # the pattern order rules therefore "grep -f" must not be used here
    #
    cat /tmp/tb/data/CATCH_ISSUES |\
    while read c
    do
      grep -m 1 -B 2 -A 3 "$c" $bak > $issuedir/issue
      if [[ $? -eq 0 ]]; then
        sed -n '3p' < $issuedir/issue | sed -e 's,['\''‘’"`], ,g' > $issuedir/title
        break
      fi
    done

    if [[ ! -s $issuedir/title ]]; then
      grep -A 1 " \* ERROR: $short.* failed (.* phase):" $bak | tail -n 1 > $issuedir/title
    fi

    if [[ -n "$(grep -e "ERROR: .* failed (test phase)" $bak)" ]]; then
      foundTestIssue
    fi

    # if the issue text is too big, then delete 1st line
    #
    if [[ $(wc -c < $issuedir/issue) -gt 1024 ]]; then
      sed -i -e "1d" $issuedir/issue
    fi

    grep -q '\[\-Werror=terminate\]' $issuedir/title
    if [[ $? -eq 0 ]]; then
      # re-try to build the failed package with default CXX flags
      #
      grep -q "=$failed cxx" /etc/portage/package.env/cxx 2>/dev/null
      cat <<EOF >> $issuedir/issue

The behaviour "-Werror=terminate" is forced at the tinderbox for GCC-6 to help stabilizing it.

EOF

      if [[ $? -ne 0 ]]; then
        echo "=$failed cxx" >> /etc/portage/package.env/cxx
        try_again=1
      fi
    fi
  fi
}


# try to match title to a tracker bug
# the BLOCKER file contains 3-line-paragraphs like:
#
#   # comment
#   <bug id>
#   <pattern>
#   ...
#
# if <pattern> is defined more than once then the first makes it
#
function SearchForBlocker() {
  block=""
  while read pattern
  do
    grep -q -E -e "$pattern" $issuedir/title
    if [[ $? -eq 0 ]]; then
      # no grep -E here, instead -F
      #
      block="-b $(grep -m 1 -B 1 -F "$pattern" /tmp/tb/data/BLOCKER | head -n 1)"
      break
    fi
  done < <(grep -v -e '^#' -e '^[1-9].*$' /tmp/tb/data/BLOCKER)     # skip comments and bug id lines
}


# put findings + links into the email body
#
function SearchForAnAlreadyFiledBug() {
  bsi=$issuedir/bugz_search_items     # easier handling by using a file
  cp $issuedir/title $bsi

  # get away line numbers, certain special terms and characters
  #
  sed -i  -e 's,&<[[:alnum:]].*>,,g'  \
          -e 's,['\''‘’"`], ,g'       \
          -e 's,/\.\.\./, ,'          \
          -e 's,:[[:alnum:]]*:[[:alnum:]]*: , ,g' \
          -e 's,.* : ,,'              \
          -e 's,[<>&\*\?], ,g'        \
          -e 's,[\(\)], ,g'           \
          $bsi

  # for the file collision case: remove the package version (from the installed package)
  #
  grep -q "file collision" $bsi
  if [[ $? -eq 0 ]]; then
    sed -i -e 's/\-[0-9\-r\.]*$//g' $bsi
  fi

  # search first for the same version, then for category/package name
  # take the highest bug id, but put the summary of the newest 10 bugs into the email body
  #
  for i in $failed $short
  do
    id=$(bugz -q --columns 400 search --show-status $i "$(cat $bsi)" | grep -e " CONFIRMED " -e " IN_PROGRESS " | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d ' ')
    if [[ -n "$id" ]]; then
      echo "CONFIRMED " >> $issuedir/bgo_result
      break
    fi

    for s in FIXED WORKSFORME DUPLICATE
    do
      id=$(bugz -q --columns 400 search --show-status --resolution "$s" --status RESOLVED $i "$(cat $bsi)" | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d ' ')
      if [[ -n "$id" ]]; then
        echo "$s " >> $issuedir/bgo_result
        break 2
      fi
    done
  done
}


# compile a command line ready for copy+paste to file a bug
# and add latest 20 b.g.o. search results
#
function AddBugzillaData() {
  if [[ -n "$id" ]]; then
    cat << EOF >> $issuedir/body
  https://bugs.gentoo.org/show_bug.cgi?id=$id

  bgo.sh -d ~/img?/$name/$issuedir -i $id -c 'got at the $keyword amd64 chroot image $name this : $(cat $issuedir/title)'

EOF

  else
    echo -e "  bgo.sh -d ~/img?/$name/$issuedir $block\n" >> $issuedir/body

    h='https://bugs.gentoo.org/buglist.cgi?query_format=advanced&short_desc_type=allwordssubstr'
    g='stabilize|Bump| keyword| bump'

    echo "  OPEN:     ${h}&resolution=---&short_desc=${short}" >> $issuedir/body
    bugz --columns 400 -q search --show-status      $short | grep -v -i -E "$g" | sort -u -n -r | head -n 20 >> $issuedir/body

    echo "" >> $issuedir/body
    echo "  RESOLVED: ${h}&bug_status=RESOLVED&short_desc=${short}" >> $issuedir/body
    bugz --columns 400 -q search --status RESOLVED  $short | grep -v -i -E "$g" | sort -u -n -r | head -n 20  >> $issuedir/body
  fi

  # this newline makes the copy+paste of the last line of the email body more convenient
  #
  echo >> $issuedir/body
}

# helper of GotAnIssue()
# create an email containing convenient links and a command line ready for copy+paste
#
function CompileIssueMail() {
  emerge -p --info $short &> $issuedir/emerge-info.txt

  AddMailAddresses
  ClassifyIssue

  # shrink too long error messages
  #
  sed -i -e 's,/[^ ]*\(/[^/:]*:\),/...\1,g' $issuedir/title

  # kick off hex addresses and such stuff to improve search results matching in b.g.o.
  #
  sed -i  -e 's/0x[0-9a-f]*/<snip>/g' \
          -e 's/: line [0-9]*:/:line <snip>:/g' \
          -e 's/[0-9]* Segmentation fault/<snip> Segmentation fault/g' \
          -e 's/Makefile:[0-9]*/Makefile:<snip>/g' \
          $issuedir/title

  SearchForBlocker
  sed -i -e "s,^,$failed : ," $issuedir/title

  # copy the issue to the email body before it is furnished for b.g.o. as comment#0
  #
  cp $issuedir/issue $issuedir/body
  AddMetainfoToBody
  AddWhoamiToIssue

  # report languages and compilers
  #
  cat << EOF >> $issuedir/issue
gcc-config -l:
$(gcc-config -l                   )
$( [[ -x /usr/bin/llvm-config ]] && echo llvm-config: && llvm-config --version )
$(eselect python  list 2>/dev/null)
$(eselect ruby    list 2>/dev/null)
$( [[ -x /usr/bin/java-config ]] && echo java-config: && java-config --list-available-vms --nocolor )
$(eselect java-vm list 2>/dev/null)

emerge -qpv $short
$(emerge -qpv $short 2>/dev/null)
EOF

  if [[ -s $issuedir/title ]]; then
    # b.g.o. has a limit for "Summary" of 255 chars
    #
    if [[ $(wc -c < $issuedir/title) -gt 255 ]]; then
      truncate -s 255 $issuedir/title
    fi
    SearchForAnAlreadyFiledBug
  fi
  AddBugzillaData

  # should be the last step b/c uuencoded attachments might be very large
  # and therefore b.g.o. search results aren't shown by Thunderbird
  #
  # the $issuedir/_* files are not part of the b.g.o. record
  #
  AttachFilesToBody $issuedir/emerge-info.txt $issuedir/files/* $issuedir/_*

  # give write perms to non-root/portage user too
  #
  chmod    777  $issuedir/{,files}
  chmod -R a+rw $issuedir/
}


# guess the failed package name and its log file name
#
function setFailedAndShort()  {
  failedlog=$(grep -m 1 "The complete build log is located at" $bak | cut -f2 -d"'" -s)
  if [[ -z "$failedlog" ]]; then
    failedlog=$(grep -m 1 -A 1 "', Log file:" $bak | tail -n 1 | cut -f2 -d"'" -s)
    if [[ -z "$failedlog" ]]; then
      failedlog=$(grep -m 1 "^>>>  '" $bak | cut -f2 -d"'" -s)
    fi
  fi

  if [[ -n "$failedlog" ]]; then
    failed=$(basename $failedlog | cut -f1-2 -d':' -s | tr ':' '/')
  else
    failed="$(cd /var/tmp/portage; ls -1d */* 2>/dev/null)"
    if [[ -n "$failed" ]]; then
      failedlog=$(ls -1t /var/log/portage/$(echo "$failed" | tr '/' ':'):????????-??????.log 2>/dev/null | head -n 1)
    else
      failed=$(grep -m1 -F ' * Package:    ' | awk ' { print $3 } ' $bak)
    fi
  fi

  short=$(pn2p "$failed")
  if [[ ! -d /usr/portage/$short ]]; then
    Mail "warn: '$failed' and/or '$short' are invalid atoms, task: $task" $bak
    failed=""
    short=""
  fi
}


function SendoutIssueMail()  {
  # no matching pattern in CATCH_* == no title
  #
  if [[ -s $issuedir/title ]]; then
    # do not report the same issue again
    #
    grep -F -q -f $issuedir/title /tmp/tb/data/ALREADY_CATCHED
    if [[ $? -eq 0 ]]; then
      return
    fi

    cat $issuedir/title >> /tmp/tb/data/ALREADY_CATCHED
  fi

  # $issuedir/bgo_result might not exists
  #
  Mail "$(cat $issuedir/bgo_result 2>/dev/null)$(cat $issuedir/title)" $issuedir/body
}


# add all successfully emerged dependencies of $task to the world file
# otherwise we'd need to use "--deep" unconditionally
# (https://bugs.gentoo.org/show_bug.cgi?id=563482)
#
function PutDepsInWorld() {
  line=$(tac /var/log/emerge.log | grep -m 1 -E ':  === |: Started emerge on: ')
  echo "$line" | grep -q ':  === ('
  if [[ $? -eq 0 ]]; then
    echo "$line" | grep -q ':  === (1 of '
    if [[ $? -eq 1 ]]; then
      emerge --depclean --pretend --verbose=n 2>/dev/null | grep "^All selected packages: " | cut -f2- -d':' -s | xargs emerge --noreplace &>/dev/null
    fi
  fi
}


# collect files, create an email and decide, whether to send it out or not
#
function GotAnIssue()  {
  PutDepsInWorld

  # bail out immediately, no reasonable emerge log expected
  #
  fatal=$(grep -f /tmp/tb/data/FATAL_ISSUES $bak)
  if [[ -n "$fatal" ]]; then
    Finish 1 "FATAL: $fatal"
  fi

  # repeat the task if emerge was killed
  #
  grep -q -e "Exiting on signal" -e " \* The ebuild phase '.*' has been killed by signal" $bak
  if [[ $? -eq 0 ]]; then
    echo "$task" >> $pks
    Finish 1 "KILLED"
  fi

  # the shared repository solution is (sometimes) racy
  #
  grep -q -e 'AssertionError: ebuild not found for' -e 'portage.exception.FileNotFound:' $bak
  if [[ $? -eq 0 ]]; then
    echo "$task" >> $pks
    Mail "info: hit a race condition in the repository sync" $bak
    return
  fi

  # ignore certain issues, skip issue handling and continue with next task
  #
  grep -q -f /tmp/tb/data/IGNORE_ISSUES $bak
  if [[ $? -eq 0 ]]; then
    return
  fi

  # set the actual failed package
  #
  setFailedAndShort
  if [[ -z "$failed" ]]; then
    return
  fi

  CreateIssueDir
  cp $bak $issuedir

  setWorkDir

  CollectIssueFiles
  CompileIssueMail

  grep -q -e "Fix the problem and start perl-cleaner again." $bak
  if [[ $? -eq 0 ]]; then
    if [[ $try_again -eq 1 ]]; then
      task="%emerge --resume"
    else
      echo "%perl-cleaner --all" >> $pks
    fi
  fi

  if [[ $try_again -eq 0 ]]; then
    echo "=$failed" >> /etc/portage/package.mask/self
  fi

  SendoutIssueMail
}


# certain packages depend on *compiled* kernel modules
#
function BuildKernel()  {
  (
    eval $(grep -e ^CC= /etc/portage/make.conf)
    export CC

    cd /usr/src/linux     &&\
    make defconfig        &&\
    make modules_prepare  &&\
    make                  &&\
    make modules_install  &&\
    make install
  ) &>> $log

  return $?
}


# switch to highest GCC version
#
function SwitchGCC() {
  latest=$(gcc-config --list-profiles --nocolor | cut -f3 -d' ' -s | grep 'x86_64-pc-linux-gnu-.*[0-9]$' | tail -n 1)
  gcc-config --list-profiles --nocolor | grep -q "$latest \*$"
  if [[ $? -eq 1 ]]; then
    verold=$(gcc -dumpversion)
    gcc-config --nocolor $latest &>> $log
    source /etc/profile || Finish 2 "can't source /etc/profile"
    vernew=$(gcc -dumpversion)

    majold=$(echo $verold | cut -c1)
    majnew=$(echo $vernew | cut -c1)

    # rebuild kernel and toolchain after a major version number change
    #
    if [[ "$majold" != "$majnew" ]]; then
      # force this at GCC-6 for stabilization help
      #
      if [[ $majnew -eq 6 ]]; then
        sed -i -e 's/^CXXFLAGS="/CXXFLAGS="-Werror=terminate /' /etc/portage/make.conf
      fi

      cat << EOF >> $pks
%emerge --unmerge sys-devel/gcc:$verold
%fix_libtool_files.sh $verold
%revdep-rebuild --ignore --library libstdc++.so.6 -- --exclude gcc
EOF
      # without a *re*build we'd get issues like: "cc1: error: incompatible gcc/plugin versions"
      #
      if [[ -e /usr/src/linux/.config ]]; then
        (cd /usr/src/linux && make clean &>/dev/null)
        echo "%BuildKernel" >> $pks
      fi
    fi
  fi
}


# helper of RunCmd()
# it schedules follow-ups from the last emerge operation
#
function PostEmerge() {
  # prefix our log backup file with an "_" to distinguish it from portages log file
  #
  bak=/var/log/portage/_emerge_$(date +%Y%m%d-%H%M%S).log
  stresc < $log > $bak

  # don't change these config files after setup
  #
  rm -f /etc/._cfg????_{hosts,resolv.conf}
  rm -f /etc/ssmtp/._cfg????_ssmtp.conf
  rm -f /etc/portage/._cfg????_make.conf
  ls /etc/._cfg????_locale.gen &>/dev/null
  if [[ $? -eq 0 ]]; then
    echo "%locale-gen" >> $pks
    rm /etc/._cfg????_locale.gen
  fi

  etc-update --automode -5 1>/dev/null
  env-update &>/dev/null
  source /etc/profile || Finish 2 "can't source /etc/profile"

  # one of the very last step in upgrading
  #
  grep -q "Use emerge @preserved-rebuild to rebuild packages using these libraries" $bak
  if [[ $? -eq 0 ]]; then
    echo "@preserved-rebuild" >> $pks
  fi

  # build and switch to the new kernel after nearly all other things
  #
  grep -q ">>> Installing .* sys-kernel/.*-sources" $bak
  if [[ $? -eq 0 ]]; then
    last=$(ls -1dt /usr/src/linux-* | head -n 1 | cut -f4 -d'/' -s)
    link=$(eselect kernel show | tail -n 1 | sed -e 's/ //g' | cut -f4 -d'/' -s)
    if [[ "$last" != "$link" ]]; then
      eselect kernel set $last
    fi

    if [[ ! -f /usr/src/linux/.config ]]; then
      echo "%BuildKernel" >> $pks
    fi
  fi

  grep -q -e "Please, run 'haskell-updater'" -e "ghc-pkg check: 'checking for other broken packages:'" $bak
  if [[ $? -eq 0 ]]; then
    echo "%haskell-updater" >> $pks
  fi

  # switch to the new GCC soon
  #
  grep -q ">>> Installing .* sys-devel/gcc-[1-9]" $bak
  if [[ $? -eq 0 ]]; then
    echo "%SwitchGCC" >> $pks
  fi

  # prevent endless loops
  #
  n=$(wc -l < /tmp/task.history)
  if [[ $n -ge 50 ]]; then
    n=$(tail -n 50 /tmp/task.history | sort -u | wc -l)
    if [[ $n -lt 35 ]]; then
      Finish 3 "task repeating >=30%"
    fi
  fi
}


# run the command ($1) and parse its output
#
function RunCmd() {
  ($1) &>> $log
  if [[ $? -ne 0 ]]; then
    status=1
  fi

  PostEmerge

  if [[ $status -eq 0 ]]; then
    rm $bak
  else
    GotAnIssue
  fi
}


# this is the heart of the tinderbox
#
#
function WorkOnTask() {
  # status=0  ok
  # status=1  task failed
  #
  status=0
  failed=""     # hold the failed package name
  try_again=0   # 1 with default environment values (if applicable)

  if [[ "$task" =~ ^@ ]]; then

    if [[ "$task" = "@preserved-rebuild" ]]; then
      RunCmd "emerge --backtrack=200 $task"
    elif [[ "$task" = "@system" || "$task" = "@world" ]]; then
      RunCmd "emerge --backtrack=200 --deep --update --newuse --changed-use $task"
    else
      RunCmd "emerge --update $task"
    fi
    cp $log /tmp/$task.last.log

    if [[ $status -eq 0 ]]; then
      echo "$(date) ok" >> /tmp/$task.history
      if [[ "$task" = "@world" ]]; then
          echo "%emerge --depclean" >> $pks
      fi

    else
      if [[ $try_again -eq 1 ]]; then
        echo "$task" >> $pks
      else
        echo "$(date) $failed" >> /tmp/$task.history
        if [[ -n "$failed" ]]; then
          echo "%emerge --resume --skip-first" >> $pks
        elif [[ "$task" = "@preserved-rebuild" ]]; then
          Finish 3 "$task failed"
        fi
      fi
    fi
    # feed the online package database
    #
    /usr/bin/pfl &>/dev/null

  # a special command was run
  #
  elif [[ "$task" =~ ^% ]]; then
    cmd="$(echo "$task" | cut -c2-)"
    RunCmd "$cmd"
    if [[ $status -eq 1 ]]; then
      # don't care for a failed resume
      #
      if [[ ! "$cmd" =~ "perl-cleaner" && ! "$cmd" =~ " --resume" ]]; then
        # re-schedule the task but bail out too to fix breakage manually
        #
        echo -e "$task" >> $pks
        Finish 3 "command '$cmd' failed"
      fi
    fi

  else
    RunCmd "emerge --update $task"
  fi
}


# test hook, eg. to catch install artefacts
#
function pre-check() {
  exe=/tmp/pre-check.sh
  out=/tmp/pre-check.log

  if [[ ! -x $exe ]]; then
    return
  fi

  $exe &> $out
  rc=$?

  if [[ $rc -eq 0 ]]; then
    rm $out

  elif [[ $rc -gt 127 ]]; then
    Mail "$exe returned $rc, task $task" $out
    Finish 2 "error: stopped"

  else
    cat << EOF >> $out

--
seen at tinderbox image $name
log:
$( tail -n 30 $log )

--
emerge --info:
$( emerge --info --verbose=n $task 2>&1 )
EOF
    Mail "$exe : rc=$rc, task $task" $out
  fi
}


# catch QA issues
#
function ParseElogForQA() {
  f=/tmp/qafilenames

  # process all files created after the last call of ParseElogForQA()
  #
  if [[ -f $f ]]; then
    find /var/log/portage/elog -name '*.log' -newer $f  > $f
  else
    find /var/log/portage/elog -name '*.log'            > $f
  fi

  cat $f |\
  while read elogfile
  do
    # process each QA issue independent from all others
    # even for the same QA file
    #
    cat /tmp/tb/data/CATCH_ISSUES_QA |\
    while read reason
    do
      grep -q -E -e "$reason" $elogfile
      if [[ $? -eq 0 ]]; then
        failed=$(basename $elogfile | cut -f1-2 -d':' -s | tr ':' '/')
        short=$(pn2p "$failed")

        CreateIssueDir

        AddMailAddresses

        cp $elogfile $issuedir/issue
        AddWhoamiToIssue

        echo "$reason" > $issuedir/title
        SearchForBlocker
        sed -i -e "s,^,$failed : ," $issuedir/title

        grep -A 10 "$reason" $issuedir/issue > $issuedir/body
        AddMetainfoToBody

        echo -e "\nbgo.sh -d ~/img?/$name/$issuedir -s QA $block\n" >> $issuedir/body
        id=$(bugz -q --columns 400 search --show-status $short "$reason" | sort -u -n | tail -n 1 | tee -a $issuedir/body | cut -f1 -d ' ')
        AttachFilesToBody $issuedir/issue

        # if the issue wasn't found at b.g.o inform us
        #
        if [[ -z "$id" ]]; then
          SendoutIssueMail
        fi
      fi
    done
  done
}


#############################################################################
#
#       main
#
mailto="tinderbox@zwiebeltoralf.de"
tsk=/tmp/task                       # holds the current task
log=$tsk.log                        # holds always output of the running task command
pks=/tmp/packages                   # the (during setup pre-filled) package list file

export GCC_COLORS=""                # suppress colour output of gcc-4.9 and above
export GREP_COLORS="never"

# eg.: gnome_20150913-104240
#
name=$(grep '^PORTAGE_ELOG_MAILFROM="' /etc/portage/make.conf | cut -f2 -d '"' -s | cut -f1 -d ' ')

# needed for the b.g.o. comment #0
#
keyword="stable"
grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
if [[ $? -eq 0 ]]; then
  keyword="unstable"
fi

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


# re-try an interrupted task
#
if [[ -s $tsk ]]; then
  cat $tsk >> $pks
  rm $tsk
fi

while :;
do
  pre-check

  if [[ -f /tmp/STOP ]]; then
    Finish 0 "catched STOP"
  fi

  # manually up from a previously failed operation
  # b/c auto-clean can't be made to collect files first
  #
  rm -rf /var/tmp/portage/*

  date > $log
  setNextTask
  echo "$task" | tee -a $tsk.history > $tsk
  WorkOnTask
  ParseElogForQA
  rm $tsk
done
