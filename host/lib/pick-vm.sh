# Shared VM picker for interactive scripts.
# Source this file; do not execute directly.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/pick-vm.sh"
#   pick_vm "running"          # filter by state
#   pick_vm "stopped,suspended" # multiple states (comma-separated)
#   pick_vm ""                 # no filter, show all local VMs
#
# Sets VM_NAME if the user picks one, or exits on error/cancel.

pick_vm() {
    local state_filter="$1"
    local vms=()

    # Parse local VMs from tart list, optionally filtering by state
    while IFS= read -r line; do
        local source name state
        source=$(echo "$line" | awk '{print $1}')
        [[ "$source" != "local" ]] && continue

        name=$(echo "$line" | awk '{print $2}')
        state=$(echo "$line" | awk '{print $NF}')

        if [[ -n "$state_filter" ]]; then
            local match=false
            IFS=',' read -ra filters <<< "$state_filter"
            for f in "${filters[@]}"; do
                [[ "$state" == "$f" ]] && match=true
            done
            [[ "$match" != true ]] && continue
        fi

        vms+=("$name|$state")
    done < <(tart list 2>/dev/null | tail -n +2)

    if [[ ${#vms[@]} -eq 0 ]]; then
        if [[ -n "$state_filter" ]]; then
            echo "No local VMs with state: $state_filter"
        else
            echo "No local VMs found."
        fi
        exit 1
    fi

    echo "Local VMs:"
    local i=1
    for entry in "${vms[@]}"; do
        local name="${entry%%|*}"
        local state="${entry##*|}"
        printf "  %d) %s (%s)\n" "$i" "$name" "$state"
        ((i++))
    done
    echo ""

    local choice
    read -r -p "Select VM [1-${#vms[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#vms[@]} ]]; then
        echo "Invalid selection."
        exit 1
    fi

    VM_NAME="${vms[$((choice - 1))]%%|*}"
}
