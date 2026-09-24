function Verify-MsiInstallation {
    param(
        [string]$ProductId,
        [string]$ExpectedVersion,
        [object[]]$Inventory
    )
    $product = Get-ProductById $ProductId
    $pattern = [string]$product.matchPattern
    $hits = @(Find-InstalledByPattern -Pattern $pattern -Inventory $Inventory)
    if ($hits.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Found = $false; DisplayName = ''; DisplayVersion = ''; Error = 'Product not found in registry after install' }
    }
    $inst = $hits[0]
    $ver = ConvertTo-InstalledDisplayVersion $inst
    $cmp = Compare-ProductVersion $ver $ExpectedVersion
    if ($null -ne $cmp -and $cmp -eq 0) {
        return [pscustomobject]@{ Ok = $true; Found = $true; DisplayName = $inst.DisplayName; DisplayVersion = $ver; Error = '' }
    }
    return [pscustomobject]@{ Ok = $false; Found = $true; DisplayName = $inst.DisplayName; DisplayVersion = $ver; Error = ('Version mismatch, expected ' + $ExpectedVersion + ', found ' + $ver) }
}