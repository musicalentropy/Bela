#!/bin/bash
# This script uploads Pd patches to Enzienaudio's server and compiles them on Bela

pdpath=
release=1
NO_UPLOAD=0
WATCH=0
FORCE=0
COMMAND_ARGS=
RUN_PROJECT=1
RUN_MODE=foreground
EXPERT=0

BELA_PYTHON27=

SCRIPTDIR=$(dirname "$0")
[ -z $SCRIPTDIR ] && SCRIPTDIR="./" || SCRIPTDIR=$SCRIPTDIR/ 
[ -z $HVRESOURCES_DIR ] && HVRESOURCES_DIR=$SCRIPTDIR/hvresources/
. $SCRIPTDIR.bela_common || { echo "You must be in Bela/scripts to run these scripts" | exit 1; }  

projectpath="$SCRIPTDIR/../tmp/heavy/hvtemp/"

if [ -z "$BELA_PYTHON27" ]; then
    for PY in python python2.7 ; do
        python --version 2>&1 | grep "2\.7" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            BELA_PYTHON27=$PY
            break;
        fi;
    done;
fi;

if [ -z "$BELA_PYTHON27" ]; then
    echo "It looks like you might not have python2.7 installed. If you do, please specify the path
    to your python2.7 executable in the environmental variable \$BELA_PYTHON27"
    exit 1;
fi;


usage_brief(){
	printf "Usage: $THIS_SCRIPT path/to/project "
    printf '[-o] [--noupload] [-r|--release release] '
	build_script_usage_brief
	run_script_usage_brief
	echo
}

usage ()
{
usage_brief
echo "
example: build_pd.sh -o ../projects/heavy/hello-world ../projects/heavy/pd/hello-world
      
This program compiles a PureData patch using the online Heavy Compiler. Before using this
script you need to have set up your Enzien Audio account and familiarized yourself with the
information available here https://github.com/BelaPlatform/Bela/wiki/Running-Puredata-patches-on-Bela#heavy.

Heavy-specific options:
	-r : builds against a specific Heavy release. Default is: $release (stable)
            ( see revision list here https://enzienaudio.com/a/releases )
	--noupload : does not use the online compiler, only compiles the current source files.
	-o arg : sets the path where files returned from the online compiler are stored.
"
	build_script_usage
	run_script_usage
}

[ -z "$ENZIENAUDIO_COM_PATCH_NAME" ] && ENZIENAUDIO_COM_PATCH_NAME=bela

while [ -n "$1" ]
do
	case $1 in
		-c)
			shift
			COMMAND_ARGS="$1"
		;;
		-b)
			RUN_MODE=screen
		;;
		-f)
			RUN_MODE=foreground
		;;
		-s)
			RUN_MODE=screenfg
		;;
		-n)
			RUN_PROJECT=0
		;;
		-p)
			shift
			BBB_PROJECT_NAME="$1"
		;;	
		--clean)
			BBB_MAKEFILE_OPTIONS="$BBB_MAKEFILE_OPTIONS projectclean"
		;;
		--force)
			FORCE=1
		;;
		-m)
			shift
			BBB_MAKEFILE_OPTIONS="$BBB_MAKEFILE_OPTIONS $1"
		;;
		--watch)
			WATCH=1
		;;
		-o | --output )
			shift
			projectpath=$1
		;;
		-r | --release )
			shift
			release=$1
		;;
		--noupload )
			NO_UPLOAD=1
		;;
		--help|-h|-\?)
			usage
			exit
		;;
		-*)
			echo Error: unknown option $1
			usage_brief
			exit 1
		;;
		*)
			[ -z "$pdpath" ] && pdpath=$1 || {
				echo "Error: too many options $pdpath $1"
				usage_brief
				exit 1
			}
    esac
    shift
done

[ $FORCE -eq 1 ] && EXPERT=1

[ "$NO_UPLOAD" -eq 0 ] && [ -z "$pdpath" ] && { echo "Error: a path to the source folder should be provided"; exit 1; }

[ -z $BBB_PROJECT_NAME ] && BBB_PROJECT_NAME=`basename "$pdpath"`

if [ -z "$release" ]
then 
  RELEASE_STRING=
else 
  RELEASE_STRING="-r $release"
fi


# These files will be cleared from $projectpath before calling uploader.py
#TODO: get a reliable, exhaustive, up-to-date list.
HEAVY_FILES='Heavy* Hv*'

[ $EXPERT -eq 0 ] && check_board_alive
# Not sure if set_date should be taken out by expert mode ...
# The expert will have to remember to run set_date after powering up the board 
# in case the updated files are not being rebuilt
[ $EXPERT -eq 0 ] && set_date

# check if project exists
[ $FORCE -eq 1 ] ||	check_project_exists_prompt $BBB_PROJECT_NAME

#create the destination folder if it does not exist"
mkdir -p "$projectpath"

reference_time_file="$projectpath"/

uploadBuildRun(){
    if [ $NO_UPLOAD -eq 0 ]; then
        # remove old static files to avoid obsolete errors
        # make sure the path is not empty, so avoiding to rm -rf / by mistake 
        [ -z $projectpath ] && { echo 'ERROR: $projectpath is empty.'; exit 0; } 
        # use -rf to prevent warnings in case they do not exist
        for file in $HEAVY_FILES
	    do 
	        rm -rf "$projectpath"/$file
	    done
        
		echo "Invoking the online compiler..."
        # invoke the online compiler
        "$BELA_PYTHON27" $HVRESOURCES_DIR/uploader.py "$pdpath"/ -n $ENZIENAUDIO_COM_PATCH_NAME -g c -o "$projectpath" $RELEASE_STRING ||\
            { echo "ERROR: an error occurred while executing the uploader.py script"; exit $?; }
    fi;

    echo "";

    # Test that files have been retrieved from the online compiler.
	# TODO: skip this now that uplodaer.py returns meaningful exit codes 
    for file in $HEAVY_FILES;
    do
        ls "$projectpath"/$file >/dev/null 2>&1 || { 
			[ $NO_UPLOAD -eq 0 ] && printf "The online compiler did not return all the files or failed without notice, please try again and/or change HEAVY_FILES to be less strict.\n\n" ||\
			printf "Folder $projectpath does not contain a valid Heavy project\n";
			exit 1; }
    done

    # Apply any Bela-specific patches here 
    cp "$HVRESOURCES_DIR/HvUtils.h" $projectpath/ || exit 1;

    BBB_PROJECT_FOLDER=$BBB_PROJECT_HOME"/"$BBB_PROJECT_NAME #make sure there is no trailing slash here
    BBB_NETWORK_TARGET_FOLDER=$BBB_ADDRESS:$BBB_PROJECT_FOLDER

    # check how to copy/sync render.cpp file...
    # check if custom heavy/render.cpp file is provided in the input folder
    # TODO: extend this to all non-Pd files
    CUSTOM_RENDER_SOURCE_PATH="$pdpath/heavy/render.cpp"
    if [ -f "$CUSTOM_RENDER_SOURCE_PATH" ]; then
        echo "Found custom heavy/render.cpp file in input folder, using that one instead of the default one.";
        cp "$CUSTOM_RENDER_SOURCE_PATH" "$projectpath/render.cpp" || exit 1
    else
        echo "Using Heavy default render.cpp"
        cp "$HVRESOURCES_DIR/render.cpp" "$projectpath/render.cpp" || exit 1
    fi
    
    echo "Updating files on board..."
    # HvContext* files tend to hang when transferring with rsync because they are very large and -c checksum takes a lot, I guess
    
    touch $reference_time_file
    # Transfer the files 
    rsync -ac --out-format="   %n" --no-t --delete-during --exclude='HvContext_'$ENZIENAUDIO_COM_PATCH_NAME'.*' --exclude=build --exclude=$BBB_PROJECT_NAME "$projectpath"/ "$BBB_NETWORK_TARGET_FOLDER" &&\
        { [ $NO_UPLOAD -eq 1 ] || scp "$projectpath"/HvContext* $BBB_NETWORK_TARGET_FOLDER; } ||\
	{ echo "ERROR: while synchronizing files with the BBB. Is the board connected?"; exit 1; }

    # TODO: rsync should upload a list of modified files, so that the corresponding objects can be deleted
    # TODO: this should be run only when Heavy_bela.h changes. Otherwise render is recompiled every time for no good reason
    #ssh $BBB_ADDRESS "rm -rf ${BBB_PROJECT_FOLDER}/build/render.*" 

    #produce a list of files which content has changed (not just the date)
    # remove old executable to force re-linking
    #if [ $NO_UPLOAD -eq 0 ]; then
    #    ssh $BBB_ADDRESS "rm -rf "$BBB_PROJECT_FOLDER/$BBB_PROJECT_NAME;
    #fi;
    # Make new Bela executable and run
    # It does not look very nice that we type the same things over and over
    # but that is because each line is an ssh session in its own right
    MAKE_COMMAND="make --no-print-directory QUIET=true -C $BBB_BELA_HOME PROJECT='$BBB_PROJECT_NAME' CL='$COMMAND_ARGS' $BBB_MAKEFILE_OPTIONS"
    if [ $RUN_PROJECT -eq 0 ]
    then
        echo "Building project..."
        ssh $BBB_ADDRESS "$MAKE_COMMAND"
    else
	    case_run_mode
    fi
} #uploadBuildRun

uploadBuildRun

if [ $WATCH -ne 0 ]; then
	BACK_NO_UPLOAD=$NO_UPLOAD
	while true
	do
		# actually we are watching multiple paths : $pdpath and $HVRESOURCES_DIR
		# so that it is easier to edit hvresources code without risk of being 
		# overwritten, but we avoid mentioning it to the end user, otherwise they
		# get confused.
		echo "Waiting for changes in $pdpath, or press ctrl-c to terminate"
		while sleep 1
		do
			folder_has_changed "$pdpath" "$reference_time_file" && {
				echo "Content of $pdpath has changed"
				break
			}
			folder_has_changed "$HVRESOURCES_DIR" "$reference_time_file" && {
				echo "Content of "$HVRESOURCES_DIR" has changed"
				break
			}
		done
		echo "Files changed"
		# if .pd files did not change, no point in re-uploading
		folder_has_changed "$pdpath" "$reference_time_file" "\.pd" &&\
			NO_UPLOAD=$BACK_NO_UPLOAD || NO_UPLOAD=1
		uploadBuildRun
	done
fi;
