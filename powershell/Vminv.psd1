@{
  RootModule        = 'Vminv.psm1'
  ModuleVersion     = '0.3.0'
  GUID              = 'b6d2e6a4-7c3e-4f2a-9c1d-0a1b2c3d4e5f'
  Author            = 'vminv'
  Description       = 'Read-only VMware vSphere pre-migration inventory & assessment (PowerCLI path). Mirrors the bash+govc implementation and the shared output schema (share/schema.json).'
  PowerShellVersion = '7.0'
  # PowerCLI is required for LIVE collection (not for fixture-mode tests).
  RequiredModules   = @()  # 'VMware.PowerCLI' — installed by setup.ps1; left soft to allow offline tests
  FunctionsToExport = '*'
  CmdletsToExport   = @()
  AliasesToExport   = @()
  PrivateData = @{ PSData = @{ Tags = @('VMware','vSphere','migration','inventory','read-only') } }
}
