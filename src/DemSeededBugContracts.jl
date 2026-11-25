dem_seeded_bug_classes() = collect(DEM_SEEDED_BUG_CLASSES)

function dem_seeded_contract_summary(contract::DemSeededBugContract)
    return dem_contract_public_metadata(contract)
end
