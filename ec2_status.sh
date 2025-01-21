#!/bin/bash

# Set your AWS username here
AWS_USERNAME="your-aws-username"

# Function to check AWS credentials
check_aws_login() {
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        echo "Error: Not logged in. Please run 'aws configure' to set up your AWS credentials."
        exit 1
    fi
}

# Function to list unique simplified cluster names and their overall status
list_clusters() {
    echo "Fetching simplified cluster names and their overall status..."

    # Define color codes
    GREEN=$(tput setaf 2)  # Green for "running"
    RED=$(tput setaf 1)    # Red for "stopped"
    YELLOW=$(tput setaf 3) # Yellow for "pending" or "starting"
    RESET=$(tput sgr0)     # Reset to default color

    # Fetch cluster data and format with color-coded statuses
    data=$(aws ec2 describe-instances \
        --filters "Name=tag:user,Values=${AWS_USERNAME}" \
        --query "Reservations[*].Instances[*].{ClusterName: Tags[?Key=='cluster_name'] | [0].Value, State: State.Name}" \
        --output json | jq -r '
        flatten |
        group_by(.ClusterName)[] |
        {ClusterName: (.[0].ClusterName | sub("^[^_]+_"; "")),
         State: (map(.State) | unique | join(","))} |
        [.ClusterName, .State] | @tsv' | while IFS=$'\t' read -r cluster state; do
            # Apply color coding based on state
            if [[ $state == "running" ]]; then
                state="${GREEN}${state}${RESET}"
            elif [[ $state == "stopped" ]]; then
                state="${RED}${state}${RESET}"
            elif [[ $state == "pending" || $state == "starting" ]]; then
                state="${YELLOW}${state}${RESET}"
            fi
            printf "%-20s %-10s\n" "$cluster" "$state"
        done
    )

    # Print ASCII table header
    printf "\n%s\n" "+----------------------+------------+"
    printf "| %-20s | %-10s |\n" "Cluster Name" "State"
    printf "%s\n" "+----------------------+------------+"

    # Print formatted data
    echo "$data" | while read -r line; do
        printf "| %-20s |\n" "$line"
    done

    # Print ASCII table footer
    printf "%s\n" "+----------------------+------------+"
}

# Function to get instance details by simplified cluster name
get_instance_details_by_cluster() {
    local simple_name="$1"
    aws ec2 describe-instances \
        --filters "Name=tag:user,Values=${AWS_USERNAME}" \
        --query "Reservations[*].Instances[*].{InstanceId: InstanceId, State: State.Name, ClusterName: Tags[?Key=='cluster_name'] | [0].Value}" \
        --output json \
    | jq -r --arg cluster "_${simple_name}" '
        flatten
        | map(select(.ClusterName != null and (.ClusterName | endswith($cluster))))
        | map([.InstanceId, .State] | @tsv)
        | .[]
    ' \
    | column -t
}

# Function to perform actions (status, start, stop, restart)
perform_action() {
    local action="$1"
    local simple_name="$2"

    # Get instance IDs by flattening and filtering
    instance_ids=$(
        aws ec2 describe-instances \
            --filters "Name=tag:user,Values=${AWS_USERNAME}" \
            --query "Reservations[*].Instances[*].{InstanceId: InstanceId, ClusterName: Tags[?Key=='cluster_name'] | [0].Value}" \
            --output json \
        | jq -r --arg cluster "_${simple_name}" '
            flatten
            | map(select(.ClusterName != null and (.ClusterName | endswith($cluster))))
            | map(.InstanceId)
            | .[]
        '
    )

    if [[ -z "$instance_ids" ]]; then
        echo "No instances found for cluster: $simple_name"
        exit 1
    fi

    case "$action" in
        status)
            echo "Fetching status of instances in cluster: $simple_name..."
            details=$(get_instance_details_by_cluster "$simple_name")
            if [[ -z "$details" ]]; then
                echo "No instances found for cluster: $simple_name"
            else
                echo "$details"
            fi
            ;;
        start)
            echo "Starting instances in cluster: $simple_name..."
            aws ec2 start-instances --instance-ids $instance_ids > /dev/null
            echo "Successfully started instances in cluster: $simple_name"
            ;;
        stop)
            echo "Stopping instances in cluster: $simple_name..."
            aws ec2 stop-instances --instance-ids $instance_ids > /dev/null
            echo "Successfully stopped instances in cluster: $simple_name"
            ;;
        restart)
            echo "Restarting instances in cluster: $simple_name..."
            aws ec2 stop-instances --instance-ids $instance_ids > /dev/null
            aws ec2 start-instances --instance-ids $instance_ids > /dev/null
            echo "Successfully restarted instances in cluster: $simple_name"
            ;;
        *)
            echo "Invalid action: $action. Use 'status', 'start', 'stop', or 'restart'."
            exit 1
            ;;
    esac
}

# Main script logic
main() {
    check_aws_login

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 {list|status|start|stop|restart} [simplified_cluster_name]"
        exit 1
    fi

    local command="$1"
    local simple_name="$2"

    case "$command" in
        list)
            list_clusters
            ;;
        status|start|stop|restart)
            if [[ -z "$simple_name" ]]; then
                echo "Error: Simplified cluster name is required for $command command."
                exit 1
            fi
            perform_action "$command" "$simple_name"
            ;;
        *)
            echo "Invalid command: $command. Use 'list', 'status', 'start', 'stop', or 'restart'."
            exit 1
            ;;
    esac
}

# Run the main function with all script arguments
main "$@"
