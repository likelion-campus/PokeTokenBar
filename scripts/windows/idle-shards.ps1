# Which idle-gate shard measures which window (scripts/windows/idle-gate.ps1). Every window of the gate is in exactly one shard.
# Test-InShard THROWS for a label that is in no shard: a window forgotten here would otherwise be measured by nobody while the
# gate passed (the label is never equal to the running shard's number).
$IdleShardOf = @{
    'manual-refresh-120s' = 1; 'normal-300s' = 1; 'plaza-visible-120s' = 1; 'plaza-minimized-120s' = 1
    'popover-kit-open-120s' = 2; 'popover-sprite-open-120s' = 2; 'popover-open-120s' = 2; 'popover-closed-120s' = 2; 'popover-home-seconds-120s' = 2; 'popover-home-minutes-120s' = 2
    'popover-home-still-120s' = 3; 'popover-activity-bars-120s' = 3; 'popover-activity-heatmap-120s' = 3; 'popover-recap-open-120s' = 3; 'popover-companion-wiggle-120s' = 3; 'popover-companion-animated-120s' = 3
    'plaza-closed-120s' = 5; 'plaza-covered-120s' = 5
    'popover-page-settings-120s' = 4; 'popover-page-shop-120s' = 4; 'popover-page-bag-120s' = 4; 'popover-page-collection-120s' = 4; 'popover-page-collection-log-120s' = 4
    'popover-page-detail-120s' = 5; 'popover-page-focus-search-120s' = 5; 'popover-page-focus-left-120s' = 5; 'popover-page-focus-closed-120s' = 5
    # stage 7 Task 22: the floating pet. Shard 4 had the room (5 windows); the third pet window goes to shard 2.
    'pet-still-120s' = 4; 'pet-hidden-120s' = 4; 'pet-animated-120s' = 2
}
function Test-InShard([string]$Label, [int]$Shard) {
    if (-not $IdleShardOf.ContainsKey($Label)) { throw "idle window '$Label' is in no shard: add it to `$IdleShardOf in scripts/windows/idle-shards.ps1" }
    return ($IdleShardOf[$Label] -eq $Shard)
}
