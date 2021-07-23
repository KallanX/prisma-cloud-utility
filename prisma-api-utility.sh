#!/bin/bash

# Required defined variables for script logic.
ENDPOINT=1
ARG=$1

# Custom check to see if user has enabled custom options in functions when executing script.
if [[ -z $ARG ]];
then
    ARG='off'
fi

# cURL Array - defined here to remove repetition.
curl_args=(
    --insecure 
    --silent 
    --user USERNAME:PASSWORD
    --header "Content-Type: application/json"
)


# ~~~System Functions - functions called by user selected functions to satifsy functionality.~~~

# gatherAPI_info - called to gather information from the user on the target Prisma instance.
gatherAPI_info ()
{ 
    read -p 'Enter IP/URL for Twistlock/Anchore API (Full URL): ' IP
    read -p 'Enter Port: ' ANSWER
    
    IPSLASHCHECK=$(echo "${IP: -1}")
    if [[ $IPSLASHCHECK == "/" ]]
    then
        IP=${IP%?}
    fi

    if [[ -z $ANSWER ]];
    then
        TWISTLOCKAPI_ENDPOINT="${IP}/api/v1"
        ANCHOREAPI_ENDPOINT="${IP}/v1"
    else
        PORT=$ANSWER
        TWISTLOCKAPI_ENDPOINT="https://${IP}:${PORT}/api/v1"
        ANCHOREAPI_ENDPOINT="https://${IP}:${PORT}/v1"
    fi

    read -p 'Username: ' USERNAME
    read -sp 'Password: ' PASSWORD

    curl_args[3]="$USERNAME:$PASSWORD"

    ENDPOINT=0
}

# Just a precautionary check to make sure basic system configurations are in place before executing commands.
preFlight_check ()
{
    if [[ ENDPOINT -eq 1 ]];
    then
        gatherAPI_info
    fi

    if [[ ! -d /home/$USER/prisma-ccu/ ]];
    then
        mkdir /home/$USER/prisma-ccu/
	mkdir /home/$USER/prisma-ccu/rule-snippets/
        mkdir /home/$USER/prisma-ccu/organize/
        mkdir /home/$USER/prisma-ccu/git/
        mkdir /home/$USER/prisma-ccu/prisma-ruleset-bundles/
        mkdir /home/$USER/prisma-ccu/prisma-rules/
    fi
}

# Used to update the TIMEDATE variable when saving rulesets. Ensures time stamp will be as close to time of saving as possible.
update_time ()
{
    TIMEDATE=$(date +"%T-%m-%d-%Y")
}

# Used to update the RULETIME variable when generating rulesets. Ensures time stamp will be as close to time of generation as possible.
ruleset_time ()
{
    RULETIME=$(date +"%Y-%m-%d"'T'%T'Z')
}

# Called at the end of each function to wait for user input to continue menu loop.
pause ()
{
    read -p "Press [Enter] key to continue..." fackEnterKey
}

# Sanity check for user entered directory and file information as these can be entered in a way that causes error in ruleset manipulation.
file_directory_sanity_check ()
{
    SLASHCHECK=$(echo "${TEMPDIR: -1}")
    JSONCHECK=$(grep "json" <<<$TEMPFILENAME)

    if [[ $SLASHCHECK == "/" ]]
    then
        EDITDIR=${TEMPDIR%?}
    else
        EDITDIR=$TEMPDIR
    fi

    if [[ -z "$JSONCHECK" ]]
    then
        EDITFILENAME=$TEMPFILENAME
    else
        EDITFILENAME=${TEMPFILENAME%?????}
    fi
}

# Called to remove doc00*.json files from the /home/USER/prisma-ccu/rule-snippets directory as part of the function cleanup.
remove_rule_snippets ()
{
    echo
    echo Cleaning up...
    rm -f /home/$USER/prisma-ccu/rule-snippets/doc00*.json
}

# Function to change the 'Owner' field in rules when generating either bundles or individual JSONs.
change_rule_owner ()
{
    read -p "Do you wish to enter a custom value for 'Owner' when generating this bundle (y/n)?: " CUSTOMOWNERANSWER

    if [[ $CUSTOMOWNERANSWER == 'y' || $CUSTOMOWNERANSWER == 'yes' || $CUSTOMOWNERANSWER == 'Y' ]]
    then
        read -p "Enter name for field 'Owner' (default is username admin): " CUSTOMOWNER
    fi

    if [[ -z $CUSTOMOWNER || -z $CUSTOMOWNERANSWER ]]
    then
        CUSTOMOWNER="admin"
    fi
}

# Ask user is they wish to enable sequential numbering when generating bundles or rules.
sequential_numbering ()
{
    read -p "Enable sequential numbering when generating bundles (y/n)?: " SEQNUMANSWER

    if [[ $SEQNUMANSWER == 'yes' || $SEQNUMANSWER == 'y' || $SEQNUMANSWER == 'Y' ]]
    then
        read -p "Enter starting number for sequential numbering (1000-9000): " SEQNUM
    fi
}

# file_sed_function - conducts file edits on rule snippets before they are pushed against the target Prisma instance.
file_sed_function ()
{
    if [[ $SEQNUMANSWER == 'yes' || $SEQNUMANSWER == 'y' || $SEQNUMANSWER == 'Y' ]]
    then
        NUM=$(jq '._id' $file)
        sed -i 's/\<'$NUM'\>/'$SEQNUM'/' $file
    fi

    if [[ $CUSTOMOWNERANSWER == 'yes' || $CUSTOMOWNERANSWER == 'y' || $CUSTOMOWNERANSWER == 'Y' ]]
    then
        CHECKOWNER=$(jq --raw-output '.owner' $file)
        sed -i 's/'$CHECKOWNER'/'$CUSTOMOWNER'/' $file
    fi

    CHECKTIME=$(jq --raw-output '.modified' $file)
    sed -i 's/'$CHECKTIME'/'$RULETIME'/' $file
}

# array_sort - this function performs an array sort to rearrange elements from smallest to biggest.
# Used to assist in ID collision prevention.
array_sort ()
{
    RULESTOTAL=${#instance_rules[@]}

    for ((i = 0; i<$RULESTOTAL; i++))
    do
        for((j = 0; j<$RULESTOTAL-i-1; j++))
        do
            if [ ${instance_rules[j]} -gt ${instance_rules[$((j+1))]} ]
            then
                temp=${instance_rules[j]}
                instance_rules[$j]=${instance_rules[$((j+1))]}
                instance_rules[$((j+1))]=$temp
            fi
        done
    done
}

# Binary search function to speed up the time to find or not find matching IDs.
binary_search ()
{
    array_sort
    LENGTH=${#instance_rules[@]}

    START=0
    END=$((LENGTH - 1))

    while [[ $START -le $END && $MATCHFOUND == "FALSE" ]]
    do
        MIDDLE=$((START + ((END - START)/2)))
        ITEM_AT_MIDDLE=${instance_rules[MIDDLE]}

        if [[ $ITEM_AT_MIDDLE -eq $CHECKNUM ]]
        then
            MATCHFOUND="TRUE"
        elif [[ $ITEM_AT_MIDDLE -gt $CHECKNUM ]]
        then
            END=$((MIDDLE-1))
        elif [[ $ITEM_AT_MIDDLE -lt $CHECKNUM ]]
        then
            START=$((MIDDLE+1))
        fi
    done
}

calculate_space ()
{
    echo "Calculating ruleset space in instance..."
    echo
    array_sort
    PUSH_RULES_TOTAL=$(cd /home/$USER/prisma-ccu/rule-snippets/ && ls -1 | wc -l)
    TOTAL_AFTER_PUSH=$((${instance_rules[-1]} + $PUSH_RULES_TOTAL))
    if [[ $TOTAL_AFTER_PUSH -ge 9999 ]]
    then
        echo "WARNING: Pushing the selected ruleset to target has the potential to break Prisma rule maximum (9999)."
        echo "Please consider reorganizing instance before pushing."
        read -p "Do you wish to reorganize and continue (r), continue (c), or exit (x)?: " ANSWER
        if [[ $ANSWER == "x" ]]
        then
            echo "Exiting..."
            echo
            pause
            exit 0
        elif [[ $ANSWER == "r" ]]
        then
            echo "Reorganizing instance before continuing..."
            organize_prisma_instance
            echo "Continuing with push..."
            get_instance_rules
        elif [[ $ANSWER == "c" ]]
        then
            echo "Continuing with operation..."
        fi
    else
        echo "Calculated space is complete. No issues detected."
    fi
}

# Grab and make array from target Prisma rules.
get_instance_rules ()
{
    instance_rules=( $(curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq --raw-output '.[] | "\(._id)"') )
}

# User Selected Functions - functions ran from the looping menu.

# Pulls down the list of check IDs in target Prisma instance and allows a user to select and delete one rule.
delete ()
{
    preFlight_check

    echo
    echo
    echo Please select from the following Compliance Checks:
    echo
    sleep 1

    curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq --raw-output '.[] | "\(._id) \(.name)"'
    echo

    read -p 'Enter numerical ID (i.e. 9XXX): ' ID

    curl "${curl_args[@]}" -X DELETE $TWISTLOCKAPI_ENDPOINT/custom-compliance/${ID}

    echo
    echo Done.
    echo
    pause
}

# Pulls down rules from target Prisma instance and saves them locally in the /home/USER/prisma-ccu/ directory with time stamp.
pull ()
{
    preFlight_check
    update_time

    if [[ $ARG == '--custom' || $ARG == '-c' ]];
    then
        echo
        read -p "Enter directory for JSON file: " TEMPDIR 
        read -p "Enter name for JSON file download: " TEMPFILENAME

        file_directory_sanity_check

	curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq '.' > $EDITDIR/$EDITFILENAME.json
    else
        curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq '.' > /home/$USER/prisma-ccu/pulled-custom_compliance_rules-$TIMEDATE.json
    fi

    echo
    echo Done.
    echo
    pause
}

# Pushes JSON files with rule data to target instance. Includes ID collision logic to avoid check overwriting.
push ()
{
    PUSHCOUNT=0
    preFlight_check

    echo
    read -p 'Enable Overwrite Protection (y/n)?: ' ANSWER
    echo

    read -p "Enter directory of JSON file: " TEMPDIR 
    read -p "Enter name of JSON file for upload: " TEMPFILENAME

    echo
    echo Processing...
    echo

    file_directory_sanity_check
    
    jq -c .[] $EDITDIR/$EDITFILENAME.json | awk '{print > "/home/'$USER'/prisma-ccu/rule-snippets/doc00" NR ".json";}'

    if [[ $ANSWER == 'y' || $ANSWER == 'yes' ]]
    then
        get_instance_rules
        calculate_space
        for file in /home/$USER/prisma-ccu/rule-snippets/doc00*.json
        do
            MATCHFOUND="FALSE"
            CHECKNUM=$(jq '._id' $file)
            binary_search
            if [[ $MATCHFOUND == "TRUE" ]]
            then
                NEWNUM=$(( instance_rules[-1] + 1 ))
                sed -i 's/\<'$CHECKNUM'\>/'$NEWNUM'/' $file
                instance_rules+=("$NEWNUM")
            elif [[ $MATCHFOUND == "FALSE" ]]
            then
                instance_rules+=("$CHECKNUM")
            fi
        done
    fi

    for file in /home/$USER/prisma-ccu/rule-snippets/doc00*.json
    do
        curl "${curl_args[@]}" -X PUT --data-binary @$file $TWISTLOCKAPI_ENDPOINT/custom-compliance -o /dev/null
        PUSHCOUNT=$((PUSHCOUNT + 1))
    done

    remove_rule_snippets

    echo
    echo Done.
    echo
    echo "Total number of rules processed: " $PUSHCOUNT
    echo
    pause
}

# Push individual rules to target
push_individual_rules ()
{
    preFlight_check

    read -p "Enter ruleset directory of technology: " TEMPDIR
    echo
    echo Processing...
    echo

    file_directory_sanity_check

    for file in EDITDIR/*
    do
        CHECKNUM=$(jq '._id' $file)
        jq -c .[] $file >> /home/$USER/prisma-ccu/rule-snippets/$CHECKNUM.json
    done

    for file in /home/$USER/prisma-ccu/rule-snippets/*
    do
        curl "${curl_args[@]}" -X PUT --data-binary @$file $TWISTLOCKAPI_ENDPOINT/custom-compliance -o /dev/null
    done

    remove_rule_snippets

    echo
    echo Done.
    echo
}

# A simple edit function to view and change JSON data.
edit ()
{
    read -p "Enter directory of JSON file: " TEMPDIR 
    read -p "Enter JSON filename: " TEMPFILENAME

    file_directory_sanity_check

	RULEFILE=$EDITDIR/$EDITFILENAME.json

	if [[ -f "$RULEFILE" ]];
	then
		vim $EDITDIR/$EDITFILENAME.json
	else
		echo
		echo ERROR: JSON rule file does not exist!
		echo Try re-entering directory and filename or PULL a new ruleset from a running instance.
		echo
	fi
    pause
}

# Generates a bundled JSON file for each technology discovered within a compliation JSON. Adds sequential numbering starting from 1000.
# Also includes the ability to change 'Owner' data field and adds variable RULETIME to each generated file.
generate_prisma_ruleset_bundle ()
{
    update_time
    ruleset_time
    GENCOUNT=0

    read -p "Enter directory of JSON file: " TEMPDIR 
    read -p "Enter Prisma Ruleset filename: " TEMPFILENAME

    sequential_numbering

    change_rule_owner
    
    file_directory_sanity_check

    jq -c .[] $EDITDIR/$EDITFILENAME.json | awk '{print > "/home/'$USER'/prisma-ccu/rule-snippets/doc00" NR ".json";}'

    echo
    echo Processing...

    mkdir /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE

    for file in /home/$USER/prisma-ccu/rule-snippets/doc00*.json
    do
        file_sed_function

        TECHTYPE=$(jq --raw-output '.name' "$file" | cut -d ' ' -f 1,2)
        TECHTYPE="${TECHTYPE// /_}"
        DIRCONTENTS=$(find /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE  -printf "%f\n")
        RULESETMATCHCHECK=$(grep "$TECHTYPE" "$DIRCONTENTS" &> /dev/null)

        if [[ -z "$RULESETMATCHCHECK" ]]
        then
            touch /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE/"$TECHTYPE".json
            cat "$file" | jq '.' >> /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE/"$TECHTYPE".json
        else
            cat "$file" | jq '.' >> /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE/"$TECHTYPE".json
        fi
        GENCOUNT=$((GENCOUNT +1))
        SEQNUM=$((SEQNUM + 1))
    done

    remove_rule_snippets

    echo
    echo Done.
    echo
    echo "Total number of rules processed: " $GENCOUNT
    echo
    echo "The following Primsa Cloud Ruleset Bundles were created:"
    echo
    
    for file in /home/$USER/prisma-ccu/prisma-ruleset-bundles/$TIMEDATE/*
    do
        sed -i '$!s/}/},/' $file
        sed -i '1i [' $file
        echo "]" >> $file
        echo $file
    done
    echo
    pause
}

# Generates a individual JSON files for each check within a compliation JSON. Adds sequential numbering starting from 1000.
# Also includes the ability to change 'Owner' data field and adds variable RULETIME to each generated file.
generate_prisma_rules ()
{
    update_time
    ruleset_time
    TOTALRULECOUNT=0

    read -p "Enter directory of JSON file: " TEMPDIR
    read -p "Enter Prisma Ruleset filename: " TEMPFILENAME

    sequential_numbering

    change_rule_owner

    file_directory_sanity_check

    jq -c .[] $EDITDIR/$EDITFILENAME.json | awk '{print > "/home/'$USER'/prisma-ccu/rule-snippets/doc00" NR ".json";}'

    echo
    echo Processing...

    mkdir /home/$USER/prisma-ccu/prisma-rules/$TIMEDATE

    for file in /home/$USER/prisma-ccu/rule-snippets/doc00*.json
    do
        file_sed_function

        TECHTYPE=$(jq --raw-output '.name' "$file")
        TECHTYPE="${TECHTYPE// /_}"
        cat "$file" | jq '.' >> /home/$USER/prisma-ccu/prisma-rules/$TIMEDATE/"$TECHTYPE".json

        TOTALRULECOUNT=$((TOTALRULECOUNT + 1))
        SEQNUM=$((SEQNUM + 1))
    done

    remove_rule_snippets

    for file in /home/$USER/prisma-ccu/prisma-rules/$TIMEDATE/*
    do
        sed -i '1i [' $file
        echo "]" >> $file
    done

    echo
    echo Done.
    echo
    echo "Prisma rules have been generated in directory: /home/$USER/prisma-ccu/prisma-rules/$TIMEDATE"
    echo "Total number of rules processed: " $TOTALRULECOUNT
    echo
    pause
}

# Removes all check data within target Prisma instance.
purge_prisma_instance ()
{
    echo
    echo "The following command will remove all custom compliance rules within a Prisma Cloud instance."
    echo "NO BACKUP will be generated. Please ensure you backup rulesets before continuing."
    echo
    read -p "Do you wish to continue (y/n)?: " ANSWER
    echo

    if [[ $ANSWER == 'y' || $ANSWER == 'yes' ]]
    then
        preFlight_check
        instance_rules=( $(curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq --raw-output '.[] | "\(._id)"') )

        echo
        echo "Processing..."
        
        for ID in ${instance_rules[*]}
        do
            curl "${curl_args[@]}" -X DELETE $TWISTLOCKAPI_ENDPOINT/custom-compliance/${ID}
        done
        echo
        echo "Purge of Prisma instance complete."
    else
        echo
        echo "Exiting."
    fi

    echo
    pause
}

# A multi-step function. Pulls all rules in target, saves rules as a single JSON. Purges rules from instance and then pushes up rules with sequential numbering.
organize_prisma_instance ()
{
    preFlight_check
    update_time

    echo
    echo "Pulling and saving all rules in the target Prisma instance..."
    curl "${curl_args[@]}" -X GET $TWISTLOCKAPI_ENDPOINT/custom-compliance | jq '.' > /home/$USER/prisma-ccu/pulled-custom_compliance_rules-$TIMEDATE.json

    echo
    echo "Done."

    echo
    echo "Purging target instance of rules..."

    get_instance_rules
        
    for ID in ${instance_rules[*]}
    do
        curl "${curl_args[@]}" -X DELETE $TWISTLOCKAPI_ENDPOINT/custom-compliance/${ID}
    done

    echo
    echo "Purge of Prisma instance complete."

    echo
    echo "Pushing rules with sequential numbering."

    SEQNUM=1000
    jq -c .[] /home/$USER/prisma-ccu/pulled-custom_compliance_rules-$TIMEDATE.json | awk '{print > "/home/'$USER'/prisma-ccu/organize/doc00" NR ".json";}'

    for file in /home/$USER/prisma-ccu/organize/doc00*.json
    do
        NUM=$(jq '._id' $file)
        sed -i 's/\<'$NUM'\>/'$SEQNUM'/' $file
        curl "${curl_args[@]}" -X PUT --data-binary @$file $TWISTLOCKAPI_ENDPOINT/custom-compliance -o /dev/null
        SEQNUM=$((SEQNUM + 1))
    done

    echo
    echo Cleaning up...
    rm -f /home/$USER/prisma-ccu/organize/doc00*.json
    echo
    echo "Done."
    pause
}

# Simple git clone function to pulld own Git content and saves to /home/USER/prisma-ccu/git/.
git_clone ()
{
    read -p 'Enter GIT Repo URL: ' GITURL
    cd /home/$USER/prisma-ccu/git && git clone $GITURL

    echo
    echo "Done. GIT Repo Generated in Directory: /home/$USER/prisma-ccu/git/"
    echo
    pause
}

# Troubleshooting function to ensure the entered Prisma instance can be reached from the host system.
test_connectivity ()
{
    preFlight_check

    NUM=$(curl -k -s -o /dev/null -w "%{http_code}\n" -X GET $TWISTLOCKAPI_ENDPOINT/_ping)

    if [[ $NUM -eq 200 ]];
    then
        echo
        echo Connection established!
        echo
    else
        echo
        echo ERROR: API NOT DETECTED!
        echo Check configuration and try again.
        echo
    fi
    pause
}

# Toggle switch to change between custom options in functions or not.
custom_toggle ()
{
    if [[ $ARG == 'off' ]];
    then
        ARG='--custom'
        echo
        echo Custom is now ON.
        echo
        pause
    elif [[ $ARG == '--custom' || $ARG == '-c' ]];
    then   
        ARG='off'
        echo
        echo Custom is now OFF.
        echo
        pause
    fi
}

# Sets up the client machine for the script to function properly. Makes directories and installs packages. Requires escalated privileges.
config_client ()
{
    echo
    echo Initializing setup...
    echo

    OSTYPE=$(grep "ID_LIKE" /etc/os-release)

    if [[ $OSTYPE == "ID_LIKE=\"centos rhel fedora\"" ]]
    then
        echo "Detected OS is: RHEL/CENTOS"
        echo "Running install..."
        sudo yum install -y -q jq vim git
    elif [[ $OSTYPE == "ID_LIKE=debian" ]]
    then
        echo "Detected OS is: Debian/Ubuntu"
        echo "Running install..."
        sudo apt -qq  -y install jq vim git
    else
        echo "Check failed to find OS type."
        echo "Please exit and install the following: jq, vim, git."
    fi

    echo "Making directories..."
    mkdir /home/$USER/prisma-ccu/
    mkdir /home/$USER/prisma-ccu/rule-snippets/
    mkdir /home/$USER/prisma-ccu/organize/
    mkdir /home/$USER/prisma-ccu/git/
    mkdir /home/$USER/prisma-ccu/prisma-ruleset-bundles/
    mkdir /home/$USER/prisma-ccu/prisma-rules/
    echo Done.
    echo
    pause
}

# Displays information for all selectable functions.
display_help ()
{
    echo
    echo "The following details helpful information about each menu option as well as useful tips for general usage."
    echo
    echo "DELETE"
    echo "The DELETE function allow for the deletion of Prisma Cloud rules. Script will reach out to user defined Prisma Cloud instance, pull down rulesets, and displays their ID."
    echo "User will then be allowed to select any ID from the list and rule will be deleted from the Prisma instance."
    echo
    echo "PUSH"
    echo "The PUSH function allows for the ability to push JSON files/bundles to any Prisma Cloud instance. User will be asked to define the directory and name of JSON file. User can also enable"
    echo "Overwrite Protection to avoid ID collision."
    echo
    echo "PULL"
    echo "The PULL function allows for the ability to pull down the complete/bulk JSON file from a user defined Prisma Cloud instance. File can either be saved to a custom location"
    echo "and/or name or be saved in the default location of /home/<Current User>/prisma-ccu/pulled-custom-compliance-rules with attached time stamp."
    echo
    echo "EDIT"
    echo "The EDIT function allows for edits to be make to any JSON file. Script utilizies VIM to edit a user defined file."
    echo
    echo "GENERATE PRISMA RULESET BUNDLE"
    echo "The GENERATE PRISMA RULESET BUNDLE generates JSON bundles, per technology, for Prisma Cloud using a user defined bulk Prisma JSON file. User can also define a custom 'Owner' field and"
    echo "all Bundles will be given an updated time/date field with time of generation. Bundles will be saved to the directory: /home/<Current User>/prisma-ccu/prisma-ruleset-bundles/."
    echo
    echo "GENERATE PRISMA RULES"
    echo "The GENERATE PRISMA RULES generates individual JSON files, per technology, from a user defind bulk Prisma JSON file. User can also define a custom 'Owner' field and"
    echo "all rules will be given an updated time/date field with time of generation. Rules will be saved in the directory: /home/<Current User>/prisma-ccu/prisma-rules/."
    echo
    echo "PURGE PRISMA INSTANCE"
    echo "Allows a user to remove all rules in a target Prisma instance. WARNING: No backup is generated. Be sure to have a copy of rulesets before executing."
    echo
    echo "ORGANIZE PRISMA INSTANCE"
    echo "Allows a user to reorganize a target Prisma instance. Useful for check sanity and to conduct cleanup. Will pull down, purge, and push rules with sequential numbering."
    echo
    echo "CLONE GIT REPOSITORY"
    echo "The CLONE GIT REPOSITORY utilizes git to clone a user defined repository and saved the content to the directory: /home/<Current User>/prisma-ccu/git/."
    echo
    echo "ENTER API ENDPOINT INFORMATION"
    echo "The ENTER API ENDPOINT INFORMATION prompts the user to enter in the Prisma Cloud API Endpoint data. Such as, IP, PORT, USERNAME, and PASSWORD. This information will then be stored"
    echo "and used by the script throughout all functions. If a user wishes to change the API data, simply re-run the ENTER API ENDPOINT INFORMATION menu option and enter new information."
    echo
    echo "TEST CONNECTIVITY"
    echo "The TEST CONNECTIVITY function is used to test the entered API Endpoint information for proper connection to the API. Useful is user needs to troubleshoot or verify if the Prisma"
    echo "Cloud API is working correctly."
    echo
    echo "CUSTOM TOGGLE"
    echo "The CUSTOM TOGGLE function allows a user to enable/disable the custom options within certain functions. A custom option within a function dictates whether or not to prompt the user"
    echo "for data entry or to default to set directories or naming conventions."
    echo
    echo "CONFIGURE CLIENT"
    echo "The CONFIGURE CLIENT menu options sets up the local machine for the script to function properly. As such, this option must be run as ROOT. The script will make directories and"
    echo "install necessary packages. Script supports OS detection. Works with Debian-based and RHEL-based Linux distributions."
    echo
    echo "DISPLAY HELP"
    echo "The DISPLAY HELP menu option displays this screen."
    echo
    echo "DISPLAY SCRIPT INFORMATION"
    echo "The DISPLAY SCRIPT INFORMATION menu option displays current script information, changelog, and available toolsets."
    echo
    echo "EXIT UTILITY"
    echo "The EXIT UTILITY menu option exits the user out of the script and back to a command prompt."
    echo
    pause
}

# Displays latest script information. Such as changelog and available toolsets.
display_script_info ()
{
    echo
    echo "The CCU (Custom Compliance Utility) allows users to manipulate Prisma Cloud rulesets via API. Script is menu based and includes a Display Help output for new users."
    echo 
    echo "Version 5.1 Changes:"
    echo " - Altered the way array of instance IDs were queried in ID collision prevention."
    echo " - Added binary_search function."
    echo " - Added calculate_space function to assist in avoidance of breaking maximum rules allowed in Prisma."
    echo
    echo "Version 5.0 Changes:"
    echo " - Changed program working directory to the home directory of user."
    echo " - Updated CONFIG\_CLIENT function to handle being ran as a less privileged user."
    echo " - Updated preFlight\_Check funtion to check for and gererate new directories."
    echo " - Updated push function to check for existing check IDs within the target Prisma instance and assign new check IDs to avoid ID collision."
    echo " - Optimized code to reduce clutter and repetition."
    echo " - Added new purge function to completely remove all rulesets in target Prisma instance."
    echo " - Added ability for user to define a custom 'owner' for each rule or to default to admin."
    echo " - Added time/date to new rules as they are pushed to the target Prisma instance."
    echo
    echo "Version 4.5 Changes:"
    echo " - Changed output directory of Prisma rules and ruleset bundles based on time and date of generation."
    echo " - Updated generation of Prisma individual rules to remove working at beginning of filename."
    echo " - Altered generated content in rule/rulesets for proper usage with Prisma PUSH script."
    echo " - Added ID sequential counter for rules when generated. This will help avoid ID collision when adding rules to Prisma instances."
    echo
    echo "Version 4.0 Changes:"
    echo " - Added the ability to generate individual Prisma JSON rule files from any bulk Prisma JSON."
    echo " - Added new menu entry for script info."
    echo " - Updated DISPLAY HELP function."
    echo " - New Functions: generate_prisma_ruleset_bundle, display_script_info"
    echo
    echo "Version 3.0 Changes:"
    echo " - Added the ability to generate Prisma Cloud JSON ruleset bundles, based on technology, from any existing bulk Prisma JSON."
    echo " - New Function: generate_tech_ruleset"
    echo " - Updated the configuration function to include OS detection for proper installation of software packages based on distribution."
    echo " - Updated PULL, PUSH, and EDIT functions for ease of use in identifying file and directory of user input."
    echo
    echo "Version 2.0 Changes:"
    echo " - Added Custom Toggle to menu options to allow user's to change custom PULL and PUSH without having to re-execute the script."
    echo " - Fixed error in saving pulled rulesets to /etc/ccu due to extra characters in the file name from Prisma Cloud URL."
    echo " - Added time and date variable to ruleset files in order to help with organization."
    echo " - Changed cURL command to array to eliminate code repetition."
    echo " - Updated menu functions and help display to reflect changes above."
    echo
    echo "Toolsets Available:"
    echo "DELETE - allows the deletion of a custom ruleset. Will display out all available ruleset and user will select from list."
    echo "PUSH - allows a user to PUSH a ruleset array to any Prisma Cloud instance with an exposed API."
    echo "PULL - allows a user to PULL all custom rules from any Prisma Cloud instance with an exposed API. Will download as a complete array."
    echo "EDIT - allows a user to EDIT a ruleset file via VIM."
    echo "GENERATE PRISMA RULESET BUNDLE - allows a user to generate Prisma JSON bundles per technology."
    echo "GENERATE PRISMA RULES - allows a user to generate single use JSON files per technology."
    echo "PURGE PRISMA INSTANCE - removes all rules in target Prisma instance."
    echo "ORGANIZE PRISMA INSTANCE - reorganizes rules in target Prisma instance with sequential numbering."
    echo "GIT CLONE - allows a user to clone a repository from GIT and is saved within /home/<Current User>/prisma-ccu/git/ directory."
    echo "TEST CONNECTIVITY - allows a user to test Prisma Cloud connectivity to ensure proper configuration before sending API calls."
    echo "CONFIG CLIENT - sets up the client machine for the utility. This includes directory creation and package installation."
    echo "DISPLAY HELP - simple help display that guides a user in utilizing the toolset."
    echo "DISPLAY SCRIPT INFORMATION - displays this screen."
    echo
    echo "Author Note: Script was written by Keith Carichner - Tapestry Technologies."
    pause
}

# Display MENU Function 
show_options ()
{
    clear 
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "    Welcome to the Custom Compliance Utility! v5.1    "
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo "1. Delete"
    echo "2. Push"
    echo "3. Push Individual Rules"
    echo "4. Pull"
    echo "5. Edit"
    echo "6. Generate Prisma Ruleset Bundles"
    echo "7. Generate Prisma Rules"
    echo "8. Purge Prisma Instance"
    echo "9. Organize Prisma Instance"
    echo "10. Clone GIT Repository"
    echo "11. Enter API Endpoint Information"
    echo "12. Test Connectivity"
    echo "13. Custom Toggle"
    echo "14. Configure Client (Requires escalated privileges.)"
    echo "15. Display Help"
    echo "16. Display Script Information"
    echo "x. Exit Utility"
}

read_options ()
{
    local choice
	read -p "Enter choice [1 - 15]: " CHOICE
	case $CHOICE in
	1) delete ;;
	2) push ;;
        3) push_individual_rules ;;
        4) pull ;;
        5) edit ;;
        6) generate_prisma_ruleset_bundle ;;
        7) generate_prisma_rules ;;
        8) purge_prisma_instance ;;
        9) organize_prisma_instance ;;
        10) git_clone ;;
        11) gatherAPI_info ;;
        12) test_connectivity ;;
        13) custom_toggle ;;
        14) config_client ;;
        15) display_help ;;
        16) display_script_info ;;
	x) exit 0;;
	*) echo Invalid selection... && sleep 2
	esac
}

while true
do
    show_options
    read_options
done
