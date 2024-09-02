#!/usr/bin/env bash
# Synopsis: Migrating channels from revision 0 to revision 1

set -e
D=$(dirname "${BASH_SOURCE[0]}")
source "$D"/../../query-bash/index.sh

on_trap() {
    set +e # do not throw error any more
    [ -n "$PASSWORD_FILE" ] && {
        echo "Deleting temp file: $PASSWORD_FILE"
        rm -f "$PASSWORD_FILE"
    }
}
trap on_trap EXIT

export PRIORITY_GAS_PRICE=${PRIORITY_GAS_PRICE:-0.01gwei}
export MAX_FEE_PER_GAS=${MAX_FEE_PER_GAS:-0.1gwei}
cast_send() {
    cast send \
         --priority-gas-price "${PRIORITY_GAS_PRICE}" --gas-price "${MAX_FEE_PER_GAS}" \
         --password-file "$PASSWORD_FILE" \
         "$@"
}
export -f cast_send

preparePasswordFile() {
    # Create a password file
    if [ -z "$PASSWORD_FILE" ]; then
        PASSWORD_FILE=$(mktemp)
        export PASSWORD_FILE
        # Ask for the password once:
        read -rsp "keystore password: " p
        echo
        echo -n "$p" > "$PASSWORD_FILE"
        unset p
    fi
}

migrateChannel() {
    MAX_UPGRADE_BATCH=100

    export C=$1
    [ -z "$C" ] && oops "channel not provided"

    echo "==== Migrating channel $C ..."

    echo "  == govMarkRegimeUpgradeStarted"
    rev=$(cast_call "$C" "currentRegimeRevision()") || oops "query currentRegimeRevision failed"
    if [ "$(parseInt256 "$rev")" == 0 ]; then
        cast_send "$C" "govMarkRegimeUpgradeStarted()"
        echo "  == ✓ govMarkRegimeUpgradeStarted DONE"
    else
        echo "  == ✓ govMarkRegimeUpgradeStarted already DONE"
    fi

    allMembers=$(allPoolMembers.list "$(channelPool "$C")")
    nMembers=$(echo "$allMembers" | wc -w)
    echo "  == Number of members: $nMembers"

    # only if there were stakers
    if [ -n "$allMembers" ]; then
        _batchMigrateStakers() {
            STAKERS="$*"
            echo "  == govUpgradeStakers $STAKERS"
            cast_send "$C" "govUpgradeStakers(address[])" "[$(echo "$STAKERS" | tr " " ",")]"
            echo "  == ✓ govUpgradeStakers DONE"
        }
        export -f _batchMigrateStakers

        # Note:
        # - Pitfall when combining xargs and sh:
        #   https://stackoverflow.com/questions/41043163/xargs-sh-c-skipping-the-first-argument
        echo "$allMembers" \
            | xargs -n"$MAX_UPGRADE_BATCH" -- bash -ec '_batchMigrateStakers "$@"' _ \
            || oops "_batchMigrateStakers migration failed"

        if [ "$nMembers" -gt 1 ]; then
            echo "  == distributeTotalInFlows"
            cast_send "$C" "distributeTotalInFlows()"
            echo "  == ✓ distributeTotalInFlows DONE"
        fi
    fi

    echo "==== ✅ Migration DONE"
}

massMigrate() {
    inputList=$1
    completionList=$2
    logsDir=$3
    [ -e "$inputList" ] || oops "inputList missing"
    [ -f "$completionList" ] || oops "completionList missing"
    [ -d "$logsDir" ] || oops "logsDir missing"

    while read -r i; do
        if ! grep -i "$i" "$completionList" >/dev/null; then
            echo "$i needs migration"
            (
                migrateChannel "$i" && { echo "$i" >> "$completionList"; }
            ) | tee -a "$logsDir"/"$i".log
        else
            echo "$i already migrated"
        fi
    done < "$inputList"
}

channelMigrationStatus() {
    C=$1
    [ -z "$C" ] && oops "channel not provided"

    currentRegime=$(parseInt256 "$(cast_call "$C" "currentRegimeRevision()")") \
        || oops "query currentRegimeRevision failed: $C"
    memberStatus=$(allPoolMembers.list "$(channelPool "$C")" \
                       | xargsNProcs "${_NPROCS:-50}" "
                         parseInt256 \$(cast_call \"$C\" \"stakerRegimeRevisions(address)\" \"\$1\")") \
        || oops "query memberStatus failed: $C"
    nMigrated=$(echo "$memberStatus" | grep -c "^1$" || true) # use "|| true" so "set -e" won't fail it
    nLeftBehind=$(echo "$memberStatus" | grep -c "^0$" || true)

    echo "$C" "$currentRegime" "$nMigrated" "$nLeftBehind"
}

channelLeakageStatus() {
    C=$1
    [ -z "$C" ] && oops "channel not provided"

    leakedAmount=$(cast from-wei "$(balanceOfDegenX "$C")")
    totalUnits=$(getTotalUnitsOfPool "$(channelPool "$C")")
    netFlow=$(cast from-wei "$(getNetFlow $_DEGENX_TOKEN "$C")")

    echo "$C" "$leakedAmount" "$totalUnits" "$netFlow"
}

distributeLeakedRewards() {
    inputList=$1
    logsDir=$2
    [ -e "$inputList" ] || oops "inputList missing"
    [ -d "$logsDir" ] || oops "logsDir missing"

    {
        awk '{ print $1 }' | while read -r i; do
            read -ra ms < <(channelMigrationStatus "$i")
            read -ra ls < <(channelLeakageStatus "$i")
            echo "${ms[0]} migrationStatus: ${ms[*]:1}, leakageStatus: ${ls[*]:1}"
            if [ "${ms[3]}" -gt 0 ]; then
                echo "Channel has not finished migration completely, so holding off distribution"
            elif [ "${ms[2]}" -eq 0 ]; then
                echo "Channel has zero members, and distribution cannot happen"
            else
                echo "Distributing leaked ${ls[1]} DEGENx"
                cast_send --confirmations 0 "$i" "distributeLeakedRewards(uint256)" 0
            fi
        done
    } < "$inputList"
}

if [ "$1" == one ]; then
    [ "$#" == 2 ] || oops "Usage: $0 one channelId"
    preparePasswordFile
    migrateChannel "$2"
elif [ "$1" == mass ]; then
    [ "$#" == 4 ] || oops "Usage: $0 mass input_list completion_list logs_dir"
    preparePasswordFile
    massMigrate "$2" "$3" "$4"
elif [ "$1" == migrationStatus ]; then
    [ "$#" == 2 ] || oops "Usage: $0 migrationStatus channelId"
    channelMigrationStatus "$2"
elif [ "$1" == extraMigrationStatus ]; then
    [ "$#" == 2 ] || oops "Usage: $0 extraMigrationStatus channelId"
    owner=$(parseAddress "$(cast_call "$2" 'owner()')")
    r1=$(parseInt256 "$(cast_call "$2" 'stakerRegimeRevisions(address)' "$owner")")
    r2=$(parseInt256 "$(cast_call "$2" 'stakerRegimeRevisions(address)' "$_AF_DEPLOYER")")
    echo "$2" "$r1" "$r2"
elif [ "$1" == leakageStatus ]; then
    [ "$#" == 2 ] || oops "Usage: $0 leakageStatus channelId"
    channelLeakageStatus "$2"
elif [ "$1" == map ]; then
    [ "$#" == 3 ] || oops "Usage: $0 map action input_file"
    xargsNProcs "${_NPROCS:-50}" "$0 \"$2\" \"\$1\"" < "$3"
elif [ "$1" == distributeLeakedRewards ]; then
    [ "$#" == 3 ] || oops "Usage: $0 distributeLeakedRewards input_list logs_dir"
    preparePasswordFile
    distributeLeakedRewards "$2" "$3"
else
    oops "Unknown command: $1"
fi
