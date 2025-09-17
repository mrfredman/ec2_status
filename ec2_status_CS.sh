#!/bin/bash

# --- Configuration ---
# Set the Key Pair Name associated with the instances you want to manage
AWS_KEY_NAME="<aAWS Key Name"" # replace with your AWS Key name

# Set the required prefix for instance Name tags
INSTANCE_NAME_PREFIX="<prefix>" # All instances should be started with the same prefix string, I use sam_

# Set the AWS Region where your instances are located
AWS_TARGET_REGION="us-east-1" # MODIFY AS NEEDED

# --- SSH Configuration ---
# Set the username required for SSH access to your instances
SSH_USER="<username>" # MODIFY AS NEEDED (e.g., ubuntu, ec2-user)

# Set the full path to the .pem private key file for SSH access
SSH_KEY_PATH="~/.ssh/<your_key>.pem" # MODIFY AS NEEDED
# --- End Configuration ---

# Function to check AWS credentials
check_aws_login() {
    if ! aws sts get-caller-identity --region ${AWS_TARGET_REGION} > /dev/null 2>&1; then
        echo "Error: Not logged in or cannot access region ${AWS_TARGET_REGION}. Please configure your AWS credentials."
        exit 1
    fi
    echo "AWS credentials verified for user: $(aws sts get-caller-identity --region ${AWS_TARGET_REGION} --query Arn --output text) in region ${AWS_TARGET_REGION}"
}

# Function to list unique derived group names (prefix removed) and their overall status
list_groups() {
    echo "Fetching instances associated with key pair '$AWS_KEY_NAME' and Name prefix '$INSTANCE_NAME_PREFIX' in region '${AWS_TARGET_REGION}'..."

    # Define color codes
    GREEN=$(tput setaf 2)  # Green for "running"
    RED=$(tput setaf 1)    # Red for "stopped"
    YELLOW=$(tput setaf 3) # Yellow for "pending", "stopping", "shutting-down"
    RESET=$(tput sgr0)     # Reset to default color

    # Fetch instance data
    local instance_data # Ensure variable is local
    instance_data=$(aws ec2 describe-instances \
        --region ${AWS_TARGET_REGION} \
        --filters "Name=key-name,Values=${AWS_KEY_NAME}" "Name=tag:Name,Values=${INSTANCE_NAME_PREFIX}*" \
        --query "Reservations[*].Instances[*].{InstanceId: InstanceId, State: State.Name, NameTag: Tags[?Key=='Name'] | [0].Value}" \
        --output json)

    # Check if AWS command returned any data structure at all
    if [[ -z "$instance_data" || "$instance_data" == "[]" || "$instance_data" == "{}" ]]; then
        echo "Warning: No instances found matching filters. Check filters and permissions."
        printf "%s\n" "+----------------------+------------+"
        printf "| %-20s | %-10s |\n" "Group Name" "State"
        printf "%s\n" "+----------------------+------------+"
        printf "%s\n" "+----------------------+------------+"
        return
    fi

    # Print header
    printf "%s\n" "+----------------------+------------+"
    printf "| %-20s | %-10s |\n" "Group Name" "State"
    printf "%s\n" "+----------------------+------------+"

    # Process data: Use printf, clean non-breaking spaces (U+00A0 -> U+0020) using sed,
    # then process with jq filter (suffix removal part commented out), sort, and read loop.
    printf "%s" "$instance_data" | sed $'s/\xC2\xA0/ /g' | jq -r --arg prefix "$INSTANCE_NAME_PREFIX" '
        flatten |
        map(select(.NameTag != null)) |
        map(. + {
             # DerivedGroupName: Remove prefix.
             DerivedGroupName: (.NameTag | sub("^"+$prefix; ""))
           }) |
        # Group by the derived GroupName
        group_by(.DerivedGroupName)[] |
        # Get the group name and unique states for each group
        {
            GroupName: .[0].DerivedGroupName,
            State: (map(.State) | unique | join(","))
        } |
        # Format as TSV
        [.GroupName, .State] | @tsv
    ' | sort | while IFS=$'\t' read -r group_name state; do

        if [[ -z "$group_name" ]]; then
            continue # Skip empty lines, if any
        fi

        # Determine color based on state(s)
        color_state="$state" # Default, no color
        if [[ "$state" == "running" ]]; then
            color_state="${GREEN}${state}${RESET}"
        elif [[ "$state" == "stopped" ]]; then
            color_state="${RED}${state}${RESET}"
        elif [[ "$state" == *"pending"* || "$state" == *"stopping"* || "$state" == *"shutting-down"* ]]; then
             if [[ "$state" == *"stopped"* ]]; then
                 color_state="${RED}${state}${RESET}" # Prefer red if mixed stopped/transient
             elif [[ "$state" == *"running"* ]]; then
                 color_state="${YELLOW}${state}${RESET}" # Yellow if mixed running/transient
             else
                 color_state="${YELLOW}${state}${RESET}" # Yellow if just transient
             fi
        elif [[ "$state" == *"running"* && "$state" == *"stopped"* ]]; then
             color_state="${YELLOW}${state}${RESET}" # Yellow if mixed running/stopped
        fi


        # Print the row, accounting for color codes in padding
        # We need to calculate padding manually if using color
        local visible_state_len=${#state}
        local full_color_state_len=${#color_state}
        # Calculate padding needed for the second column (width 10)
        local target_width=10
        local padding_len=$(( target_width - visible_state_len ))
        # Ensure padding isn't negative if state is unexpectedly long
if (( padding_len < 0 )); then padding_len=0; fi
        printf "| %-20s | %s%*s |\n" "$group_name" "$color_state" "$padding_len" ""

    done # End of while loop

    # Print ASCII table footer
    printf "%s\n" "+----------------------+------------+"
}


# Function to get instance details by derived group name (prefix removed)
get_instance_details_by_group() {
    local target_group_name_no_prefix="$1"
    echo "Fetching instance details for group '$target_group_name_no_prefix' (derived from Name tag starting with '$INSTANCE_NAME_PREFIX') in region ${AWS_TARGET_REGION}..."

    # Fetch relevant instance data
    local instance_data
    instance_data=$(aws ec2 describe-instances \
        --region ${AWS_TARGET_REGION} \
        --filters "Name=key-name,Values=${AWS_KEY_NAME}" "Name=tag:Name,Values=${INSTANCE_NAME_PREFIX}${target_group_name_no_prefix}*" \
        --query "Reservations[*].Instances[*].{InstanceId: InstanceId, State: State.Name, NameTag: Tags[?Key=='Name'] | [0].Value, PublicIp: PublicIpAddress}" \
        --output json)

    # Clean potential non-breaking spaces using sed and process with jq
    printf "%s" "$instance_data" | sed $'s/\xC2\xA0/ /g' | jq -r --arg groupNameNoPrefix "$target_group_name_no_prefix" --arg prefix "$INSTANCE_NAME_PREFIX" '
        flatten |
        map(select(.NameTag != null)) | # Ensure Name tag exists
        # Derive group name for filtering
        map(select( (.NameTag | sub("^"+$prefix; "")) == $groupNameNoPrefix )) |
        # Format output
        map([.InstanceId, .State, (.PublicIp // "-"), .NameTag] | @tsv) | # Use // "-" for null Public IP
        .[]
    ' | column -t -s $'\t' # Format into columns
}

# Function to get instance IDs for a specific derived group name (prefix removed)
get_instance_ids_for_group() {
    local target_group_name_no_prefix="$1"

    # Fetch instance data
     local instance_data
     instance_data=$(aws ec2 describe-instances \
        --region ${AWS_TARGET_REGION} \
        --filters "Name=key-name,Values=${AWS_KEY_NAME}" "Name=tag:Name,Values=${INSTANCE_NAME_PREFIX}${target_group_name_no_prefix}*" \
        --query "Reservations[*].Instances[*].{InstanceId: InstanceId, NameTag: Tags[?Key=='Name'] | [0].Value}" \
        --output json)

    # Clean potential non-breaking spaces using sed and process with jq
    printf "%s" "$instance_data" | sed $'s/\xC2\xA0/ /g' | jq -r --arg groupNameNoPrefix "$target_group_name_no_prefix" --arg prefix "$INSTANCE_NAME_PREFIX" '
        flatten |
        map(select(.NameTag != null)) |
        # Derive group name for filtering
        map(select( (.NameTag | sub("^"+$prefix; "")) == $groupNameNoPrefix )) |
        # Extract InstanceIds
        map(.InstanceId) |
        .[]
    '
}

# *** NEW FUNCTION to generate SSH commands ***
generate_ssh_commands_for_ids() {
    local instance_ids_list="$1" # Space-separated list of instance IDs
    local ssh_user="$2"
    local ssh_key_path="$3"
    local aws_region="$4"

    echo
    echo "--- Generating SSH Commands ---"
    echo "Fetching Public IPs for instances: ${instance_ids_list}..."

    # AWS CLI command to get Instance ID and Public IP for the specified running instances
    aws ec2 describe-instances \
      --region "$aws_region" \
      --instance-ids ${instance_ids_list} \
      --filter Name=instance-state-name,Values=running \
      --query 'Reservations[*].Instances[*].[InstanceId, PublicIpAddress]' \
      --output text | \
    while read -r INSTANCE_ID PUBLIC_IP; do
      # Check if a valid Public IP was returned (not "None" or empty)
      if [[ "$PUBLIC_IP" != "None" && ! -z "$PUBLIC_IP" ]]; then
        echo "---------------------------------"
        echo " Instance ID: $INSTANCE_ID"
        echo " Public IP:   $PUBLIC_IP"
        echo " SSH Command:"
        # Expand ~ in key path if present
        eval expanded_key_path=$ssh_key_path
        printf " ssh -i %s %s@%s\n" "$expanded_key_path" "$ssh_user" "$PUBLIC_IP"
      else
        # Handle cases where instance has no Public IP (e.g., private subnet)
        echo "---------------------------------"
        echo " Instance ID: $INSTANCE_ID (No Public IP found)"
      fi
    done
    echo "---------------------------------"
    echo "--- SSH Command Generation Complete ---"
    echo
}

# Function to perform actions (status, start, stop, restart)
perform_action() {
    local action="$1"
    local target_group_name_no_prefix="$2" # User provides name without prefix

    echo "Finding instances for group '$target_group_name_no_prefix' (Name starting with '$INSTANCE_NAME_PREFIX') associated with key '$AWS_KEY_NAME' in region ${AWS_TARGET_REGION}..."
    local instance_ids # Make local
    instance_ids=$(get_instance_ids_for_group "$target_group_name_no_prefix")

    if [[ -z "$instance_ids" ]]; then
        echo "Error: No instances found matching group '$target_group_name_no_prefix' with prefix '${INSTANCE_NAME_PREFIX}'."
        exit 1
    fi

    # Convert newline-separated IDs to space-separated list
    local instance_ids_list # Make local
    instance_ids_list=$(echo "$instance_ids" | tr '\n' ' ')
    # Count the instances
    local instance_count # Make local
    instance_count=$(echo "$instance_ids" | wc -l | xargs) # xargs trims whitespace

    echo "Attempting to $action $instance_count instance(s) in group '$target_group_name_no_prefix'..."
    # echo "Instance IDs: $instance_ids_list" # Optional: Uncomment to see IDs

    case "$action" in
        status)
            # Status logic updated to use the modified get_instance_details_by_group
            echo "Fetching status..."
            local details # Make local
            details=$(get_instance_details_by_group "$target_group_name_no_prefix")
            if [[ -z "$details" ]]; then
                echo "No instance details found for group: $target_group_name_no_prefix"
            else
                printf "%-20s %-15s %-15s %s\n" "InstanceId" "State" "Public IP" "Full Name Tag"
                echo "---------------------------------------------------------------------"
                echo "$details"
            fi
            ;;
        start)
            # Execute command and suppress stdout JSON
            aws ec2 start-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list > /dev/null
            # Check exit status ($? == 0 means success)
            if [[ $? -eq 0 ]]; then
                echo "Successfully issued start command for $instance_count instance(s) in group '$target_group_name_no_prefix'."

                # *** ADDED: Wait for instances to run and generate SSH commands ***
                echo "Waiting for instance(s) to reach 'running' state (this may take a moment)..."
                if aws ec2 wait instance-running --region ${AWS_TARGET_REGION} --instance-ids ${instance_ids_list}; then
                    echo "Instance(s) confirmed running. Fetching IPs..."
                    sleep 5 # Brief pause to allow IPs to fully propagate if needed
                    generate_ssh_commands_for_ids "${instance_ids_list}" "${SSH_USER}" "${SSH_KEY_PATH}" "${AWS_TARGET_REGION}"
                else
                    echo "Warning: 'aws ec2 wait instance-running' failed or timed out. Instances might still be starting."
                    echo "Run 'status' command later to check and manually fetch IPs if needed."
                fi
                # *** END ADDED SECTION ***

                echo "Use '$0 status $target_group_name_no_prefix' to verify details."
            else
                echo "Error: AWS command failed to start instances."
                echo "Check IAM permissions ('ec2:StartInstances') or run manually:"
                echo "aws ec2 start-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list"
                exit 1
            fi
            ;;
        stop)
             # Execute command and suppress stdout JSON
            aws ec2 stop-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list > /dev/null
            # Check exit status
            if [[ $? -eq 0 ]]; then
                 echo "Successfully issued stop command for $instance_count instance(s) in group '$target_group_name_no_prefix'."
                 echo "Use '$0 status $target_group_name_no_prefix' shortly to verify."
            else
                echo "Error: AWS command failed to stop instances."
                echo "Check IAM permissions ('ec2:StopInstances') or run manually:"
                echo "aws ec2 stop-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list"
                exit 1
            fi
            ;;
        restart)
            echo "Issuing stop command..."
            aws ec2 stop-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list > /dev/null
            if [[ $? -ne 0 ]]; then
                echo "Error: Failed during stop phase of restart."
                echo "Check IAM permissions ('ec2:StopInstances') or run manually:"
                echo "aws ec2 stop-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list"
                exit 1
            fi

            echo "Waiting for instance(s) to reach 'stopped' state..."
            # Use waiter for stopped state
            if aws ec2 wait instance-stopped --region ${AWS_TARGET_REGION} --instance-ids ${instance_ids_list}; then
                 echo "Instance(s) confirmed stopped."
            else
                 echo "Warning: 'aws ec2 wait instance-stopped' failed or timed out. Proceeding with start command anyway..."
            fi
            # Optional extra sleep if needed after stopped waiter
            # sleep 5

            echo "Issuing start command..."
            aws ec2 start-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list > /dev/null
             if [[ $? -eq 0 ]]; then
                 echo "Successfully issued start command for $instance_count instance(s) in group '$target_group_name_no_prefix'."

                 # *** ADDED: Wait for instances to run and generate SSH commands ***
                 echo "Waiting for instance(s) to reach 'running' state (this may take a moment)..."
                 if aws ec2 wait instance-running --region ${AWS_TARGET_REGION} --instance-ids ${instance_ids_list}; then
                     echo "Instance(s) confirmed running. Fetching IPs..."
                     sleep 5 # Brief pause to allow IPs to fully propagate if needed
                     generate_ssh_commands_for_ids "${instance_ids_list}" "${SSH_USER}" "${SSH_KEY_PATH}" "${AWS_TARGET_REGION}"
                 else
                     echo "Warning: 'aws ec2 wait instance-running' failed or timed out. Instances might still be starting."
                     echo "Run 'status' command later to check and manually fetch IPs if needed."
                 fi
                 # *** END ADDED SECTION ***

                 echo "Use '$0 status $target_group_name_no_prefix' to verify details."
            else
                echo "Error: Failed during start phase of restart. Instances might be stopped."
                echo "Check IAM permissions ('ec2:StartInstances') or run manually:"
                 echo "aws ec2 start-instances --region ${AWS_TARGET_REGION} --instance-ids $instance_ids_list"
                exit 1
            fi
            ;;
        *)
            # This case should not be reached due to main() checks
            echo "Internal error: Invalid action '$action' passed to perform_action."
            exit 1
            ;;
    esac
}

# Main script logic
main() {
    # Check login early
    check_aws_login || exit 1

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 {list | status <group_name> | start <group_name> | stop <group_name> | restart <group_name>}"
        echo ""
        echo "Manages EC2 instances associated with key pair '$AWS_KEY_NAME' and Name tag prefix '$INSTANCE_NAME_PREFIX' in region '${AWS_TARGET_REGION}'."
        echo "Groups are derived from the 'Name' tag (prefix removed)."
        echo "Provide the <group_name> WITHOUT the '$INSTANCE_NAME_PREFIX' prefix."
        echo ""
        echo "Commands:"
        echo "  list             : List derived group names (prefix removed) and their overall state."
        echo "  status <name>    : Show status of instances in the specified group (includes Public IP)."
        echo "  start <name>     : Start instances in the group, wait until running, then output SSH commands."
        echo "  stop <name>      : Stop instances in the specified group."
        echo "  restart <name>   : Stop instances, wait until stopped, start them, wait until running, then output SSH commands."
        exit 1
    fi

    # Check if placeholder values are still present
    if [[ "$AWS_KEY_NAME" == "your-key-pair-name" || "$AWS_TARGET_REGION" == "your-region" || "$SSH_USER" == "your-ssh-user" || "$SSH_KEY_PATH" == "~/.ssh/your-key-name.pem" ]]; then
        echo "Error: Please edit the script and set the AWS_KEY_NAME, AWS_TARGET_REGION, SSH_USER, and SSH_KEY_PATH variables in the Configuration section."
        exit 1
    fi

    local command="$1"
    local group_name_no_prefix="$2" # User provides name without prefix

    case "$command" in
        list)
            list_groups
            ;;
        status|start|stop|restart)
            if [[ -z "$group_name_no_prefix" ]]; then
                echo "Error: A group name (derived from the 'Name' tag, without prefix '$INSTANCE_NAME_PREFIX') is required for the '$command' command."
                echo "Use the 'list' command to see available group names."
                exit 1
            fi
            perform_action "$command" "$group_name_no_prefix"
            ;;
        *)
            echo "Invalid command: $command."
            echo "Use 'list', 'status', 'start', 'stop', or 'restart'."
            exit 1
            ;;
    esac
}

# Run the main function with all script arguments
main "$@"
