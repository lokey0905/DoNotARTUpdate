# Parse only explicitly supported dumpsys fields. Missing data is not false.
function boolean(v) { return v == "true" || v == "false" }
function numeric(v) { return v ~ /^[0-9]+$/ }
function art(v) { return v == "com.android.art" || v == "com.google.android.art" }
function fail(message) { error = message }
function field(key, value) {
    if (key in fields && fields[key] != value) fail("conflicting field " key)
    fields[key] = value
}
function flush_session(    key) {
    if (sid == "") return
    if (sid in staged) fail("duplicate session " sid)
    staged[sid] = fields["staged"]
    pkg[sid] = fields["package"]
    parent[sid] = fields["parent"]
    applied[sid] = fields["applied"]
    failed[sid] = fields["failed"]
    ready[sid] = fields["ready"]
    destroyed[sid] = fields["destroyed"]
    committed[sid] = fields["committed"]
    multi[sid] = fields["multi"]
    children[sid] = fields["children"]
    for (key in fields) delete fields[key]
    sid = ""
}
function flush_apex(    key) {
    if (art(apkg)) {
        key = section SUBSEP apkg
        if (key in versions) fail("duplicate ART APEX " section)
        versions[key] = aversion
        paths[key] = apath
        factory[key] = afactory
        active[key] = aactive
    }
    apkg = aversion = apath = afactory = aactive = ""
}
function terminal(id) {
    return applied[id] == "true" || failed[id] == "true" || destroyed[id] == "true"
}
function member(list, id) { return index("," list ",", "," id ",") != 0 }
{
    sub(/\r$/, "")
    if ($0 ~ /^\*\*\* SERVICE .* DUMP TIMEOUT/ || $0 ~ /^Permission Denial:/ || $0 ~ /^Can't find service:/) {
        fail("PackageManager query failed or timed out")
        next
    }
    if ($0 ~ /^[[:space:]]*APEX session state:$/) {
        if (apex_seen) apex_unsafe = 1
        apex_sessions = 1; apex_seen = 1; next
    }
    if (apex_sessions && NF && $0 !~ /^[[:space:]]*(Active|Inactive|Factory) APEX packages:$/ &&
        !($1 == "Session" && $2 == "ID:" && numeric($3)) && $1 != "State:") apex_unsafe = 1
    if (apex_sessions && $1 == "Session" && $2 == "ID:") apex_ids++
    if (apex_sessions && $1 == "State:") {
        apex_states++
        apex_state = $0
        sub(/^[[:space:]]*State:[[:space:]]*/, "", apex_state)
        if (apex_state != "SUCCESS" && apex_state != "REVERTED" && apex_state != "ACTIVATION FAILED") apex_unsafe = 1
    }
    if ($0 ~ /^[[:space:]]*Active install sessions:$/) {
        flush_apex()
        section = ""
        if (seen_sessions++) fail("duplicate active session section")
        in_sessions = 1
        next
    }
    if ($0 ~ /^[[:space:]]*Historical install sessions:$/) {
        flush_session()
        in_sessions = 0
        seen_end = 1
        next
    }
    if ($0 ~ /^[[:space:]]*Finalized install sessions:$/) {
        # Finalized trains are separate from active sessions on newer builds.
        flush_session()
        in_sessions = 0
        next
    }
    if ($0 ~ /^[[:space:]]*Orphaned install sessions:$/) {
        fail("orphaned install sessions require inspection")
        flush_session()
        in_sessions = 0
        next
    }
    if (in_sessions && $0 ~ /^[[:space:]]*(Active )?(Child )?Session [0-9]+:$/) {
        flush_session()
        sid = $NF
        sub(/:$/, "", sid)
        next
    }
    if (in_sessions && sid == "" && NF) fail("unrecognized install session layout")
    if (in_sessions && sid != "") {
        for (i = 1; i <= NF; i++) {
            split($i, pair, "=")
            key = pair[1]; value = pair[2]
            if (key == "appPackageName") field("package", value)
            if (key == "params.isStaged") field("staged", value)
            if (key == "params.isMultiPackage") field("multi", value)
            if (key == "mParentSessionId") field("parent", value)
            if (key == "mCommitted") field("committed", value)
            if (key == "mDestroyed") field("destroyed", value)
            if (key == "mStagedSessionApplied" || key == "mSessionApplied") field("applied", value)
            if (key == "mStagedSessionFailed" || key == "mSessionFailed") field("failed", value)
            if (key == "mStagedSessionReady" || key == "mSessionReady") field("ready", value)
        }
        if (match($0, /mChildSessionIds=\[[0-9, ]*\]/)) {
            value = substr($0, RSTART, RLENGTH)
            sub(/^mChildSessionIds=\[/, "", value)
            gsub(/[] ]/, "", value)
            field("children", value)
        }
    }
    if ($0 ~ /^[[:space:]]*(Active|Inactive|Factory) APEX packages:$/) {
        apex_sessions = 0
        flush_apex()
        section = $1
        next
    }
    if (section != "") {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line ~ /^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$/) {
            flush_apex()
            apkg = line
        } else if (art(apkg)) {
            if ($1 == "Version:") aversion = $2
            if ($1 == "Path:") apath = $2
            if ($1 == "IsFactory:") afactory = $2
            if ($1 == "IsActive:") aactive = $2
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "versionCode") aversion = pair[2]
                if (pair[1] == "sourceDir") apath = pair[2]
                if (pair[1] == "isFactory") afactory = pair[2]
                if (pair[1] == "isActive") aactive = pair[2]
            }
        }
        if ($0 ~ /^[^[:space:]]/ && line !~ /^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$/) {
            flush_apex()
            section = ""
        }
    }
}
END {
    flush_session()
    flush_apex()
    if (!seen_sessions || !seen_end) fail("incomplete install session dump")
    for (id in staged) {
        if (!boolean(staged[id])) { fail("unknown staged flag " id); continue }
        if (staged[id] != "true") continue
        if (!boolean(applied[id]) || !boolean(failed[id]) || !boolean(ready[id]) || !boolean(destroyed[id])) {
            fail("unknown session state " id); continue
        }
        if (terminal(id)) continue
        # Android can finalize only the parent; child state flags may stay false.
        if (parent[id] != "-1" && parent[id] in staged && staged[parent[id]] == "true" && terminal(parent[id])) continue
        if (!boolean(multi[id]) || !boolean(committed[id]) || !(parent[id] == "-1" || numeric(parent[id]))) {
            fail("unknown session topology " id); continue
        }
        if (multi[id] != "true" && (pkg[id] == "" || pkg[id] == "null")) fail("unresolved package " id)
        busy++
        if (parent[id] != "-1") {
            p = parent[id]
            if (!(p in staged) || staged[p] != "true" || terminal(p) || multi[p] != "true" || parent[p] != "-1" || !member(children[p], id))
                fail("broken parent-child link " id)
        }
        if (multi[id] == "true") {
            n = split(children[id], ids, ",")
            if (n == 0 || children[id] == "") fail("empty staged train " id)
            for (j = 1; j <= n; j++) {
                child = ids[j]
                if (!(child in staged) || staged[child] != "true" || parent[child] != id || terminal(child)) fail("missing train child " id)
            }
        }
        if (art(pkg[id])) roots[parent[id] == "-1" ? id : parent[id]] = 1
    }
    if (!only_sessions) {
        for (candidate in paths) {
            split(candidate, parts, SUBSEP)
            if (parts[1] == "Active") { selected = parts[2]; count++ }
        }
        if (count != 1) fail("missing or ambiguous active ART")
        a = "Active" SUBSEP selected
        f = "Factory" SUBSEP selected
        if (!numeric(versions[a]) || !numeric(versions[f]) || paths[a] !~ /^\// || paths[f] !~ /^\// || !boolean(factory[a]) || factory[f] != "true" || active[a] != "true")
            fail("incomplete ART active/factory metadata")
        if (factory[a] == "true" && versions[a] != versions[f]) fail("inconsistent factory ART version")
    }
    if (error != "") { print "ERROR|" error; exit 1 }
    if (!only_sessions) print "ART|" selected "|" versions[a] "|" versions[f] "|" factory[a] "|" paths[a] "|" paths[f]
    print "BUSY|" busy + 0
    print "APEXSAFE|" ((apex_seen && apex_ids == apex_states && !apex_unsafe) ? "true" : "false")
    for (id in roots) print "PENDING|" id "|" ready[id] "|" committed[id]
}
