#!/bin/bash

HISTSESSION=`dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64`

# This utility requires bash-preexec to function, so get it.
# n.b. we presume cwd is ~
if [ ! -f ${HOME}/.bash-preexec.sh ]
then
    wget -q -O ${HOME}/.bash-preexec.sh 'https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh' 2> /dev/null ||
    curl -s -o ${HOME}/.bash-preexec.sh 'https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh' 2> /dev/null
fi
source ${HOME}/.bash-preexec.sh

# header guard
[ -n "$_SQLITE_HIST" ] && return || readonly _SQLITE_HIST=1


# Let's define some utility functions
# TODO figure out how to integrate this with the history builtins

dbhistory() {
    sqlite3 -separator '#' ${HISTDB} "select command_id, command from command where command like '%${@}%';" | awk -F'#' '/^[0-9]+#/ {printf "%8s    %s\n", $1, substr($0,index($0,FS)+1); next} { print $0; }'
}

dbhist() {
    dbhistory "$@"
}

# TODO figure out how to make this function rewrite history so the up arrow
#  (or ^r searches) give you what you ran, and not the dbexec() call.
dbexec() {
    bash -c "$(sqlite3 "${HISTDB}" "select command from command where command_id='${1}';")"
}


# The magic follows

__quote_str() {
	local str
	local quoted
	str="$1"
	quoted="'$(echo "$str" | sed -e "s/'/''/g")'"
	echo "$quoted"
}

__histdb_now_ms() {
	local ts
	ts="$(date +%s%3N 2>/dev/null || true)"
	if [[ "$ts" == *N ]]; then
		ts="$(( $(date +%s) * 1000 ))"
	fi
	echo "$ts"
}

__create_histdb() {
	if bash -c "set -o noclobber; > \"$HISTDB\" ;" &> /dev/null; then
		sqlite3 "$HISTDB" <<-EOD
		CREATE TABLE command (
			command_id INTEGER PRIMARY KEY,
			shell TEXT,
			command TEXT,
			cwd TEXT,
			return INTEGER,
			started INTEGER,
			ended INTEGER,
			shellsession TEXT,
			loginsession TEXT
		);
		EOD
	fi
}

__histdb_insert_command() {
	[[ -z ${HISTDB:-} ]] && return 1
	command -v sqlite3 >/dev/null 2>&1 || return 1

	local cmd cwd shellsession loginsession quotedloginsession quotedshellsession
	cmd="$1"
	cwd="${2:-$PWD}"
	shellsession="${3:-${HISTSESSION:-}}"
	loginsession="${4:-${LOGINSESSION:-}}"

	__create_histdb

	if [[ -n "$shellsession" ]]; then
		quotedshellsession=$(__quote_str "$shellsession")
	else
		quotedshellsession="NULL"
	fi
	if [[ -n "$loginsession" ]]; then
		quotedloginsession=$(__quote_str "$loginsession")
	else
		quotedloginsession="NULL"
	fi

	sqlite3 "$HISTDB" <<-EOD
		INSERT INTO command (shell, command, cwd, started, shellsession, loginsession)
		VALUES (
			'bash',
			$(__quote_str "$cmd"),
			$(__quote_str "$cwd"),
			'$(__histdb_now_ms)',
			$quotedshellsession,
			$quotedloginsession
		);
		SELECT last_insert_rowid();
	EOD
}

__histdb_finish_command() {
	[[ -z ${HISTDB:-} ]] && return 0
	[[ -z ${1:-} ]] && return 0
	command -v sqlite3 >/dev/null 2>&1 || return 0

	local command_id ret_value
	command_id="$1"
	ret_value="${2:-0}"

	__create_histdb
	sqlite3 "$HISTDB" <<-EOD
		UPDATE command SET
			ended='$(__histdb_now_ms)',
			return=$ret_value
		WHERE
			command_id=$command_id ;
	EOD
}

preexec_bash_history_sqlite() {
	[[ -z ${HISTDB} ]] && return 0
	local cmd
	cmd="$1"

	LASTHISTID="$(__histdb_insert_command "$cmd" "$PWD" "${HISTSESSION:-}" "${LOGINSESSION:-}")"

	echo "$cmd" >> ~/.testlog
}

precmd_bash_history_sqlite() {
	local ret_value="$?"
	if [[ -n "${LASTHISTID}" ]]; then
		__histdb_finish_command "$LASTHISTID" "$ret_value"
	fi
}

preexec_functions+=(preexec_bash_history_sqlite)
precmd_functions+=(precmd_bash_history_sqlite)
