BEGIN { FS = "|" }
NR == 1 {
    if (NF != 2 || $1 != "v1" || $2 !~ /^[a-zA-Z0-9-]+$/) bad = 1
    saved_boot = $2
    next
}
{
    # Old-boot records are never displayed or carried into the new boot.
    if (saved_boot != boot) next
    if (NF != 2 || $1 !~ /^[0-9]+$/ || seen[$1]++ ||
        $2 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}$/) bad = 1
    count++
    last_time = $2
    last_id = $1
    if ($1 == target) found = 1
}
END {
    if (!NR || bad) exit 1
    print saved_boot "|" count + 0 "|" last_time "|" last_id "|" found + 0
}
