param([string]$PostgresBin='D:\workspace\.tools\postgresql\pgsql\bin',[Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/platform-recovery.ps1')
if($env:TEST_DATABASE_URL -cne 'postgres://p2_fixture:fixture-only@127.0.0.1:55591/postgres?sslmode=disable&search_path=public'){throw 'Explicit isolated synthetic fixture required.'}
$admin=Get-DatabaseConnection $env:TEST_DATABASE_URL
$database='schema_recovery_'+[guid]::NewGuid().ToString('N')
$reader='reader_'+[guid]::NewGuid().ToString('N')
$other='owner_'+[guid]::NewGuid().ToString('N')
$connection=$admin.Clone();$connection.database=$database
New-ProtectedDirectory $EvidenceDirectory
$dump=Join-Path $EvidenceDirectory 'synthetic.dump'
$report=@{passed=$false;checks=@();formal_changes=0;provider_calls=0}
function Check([string]$Name,[bool]$Passed){if(-not $Passed){throw ('Recovery schema check failed: '+$Name)};$report.checks+=$Name}
function Reset-Fixture {
    $null=Invoke-RecoverySQL $PostgresBin $admin ('DROP DATABASE '+(Quote-PgIdentifier $database)+';')
    $null=Invoke-PostgresTool $PostgresBin pg_restore @('-w','--exit-on-error','--create','-d','postgres',$dump) $admin
}
try{
    $null=Invoke-RecoverySQL $PostgresBin $admin ('CREATE ROLE '+(Quote-PgIdentifier $reader)+'; CREATE ROLE '+(Quote-PgIdentifier $other)+';')
    $null=Invoke-RecoverySQL $PostgresBin $admin ('CREATE DATABASE '+(Quote-PgIdentifier $database)+';')
    $null=Invoke-RecoverySQL $PostgresBin $connection @"
CREATE TABLE public.run_continuation_receipts (
 request_id text PRIMARY KEY CHECK(length(request_id) BETWEEN 1 AND 128 AND request_id ~ '^[A-Za-z0-9_-]+$'),
 counter integer NOT NULL CHECK(counter>=0),
 CONSTRAINT zz_after CHECK(counter<=10));
INSERT INTO public.run_continuation_receipts VALUES('fixture',1);
GRANT SELECT ON public.run_continuation_receipts TO "$reader" WITH GRANT OPTION;
"@
    $captured=Get-DatabaseSchemaHash $PostgresBin $connection
    $metadata=Get-DatabaseMetadata $PostgresBin $connection
    $fingerprints=Get-DatabaseFingerprints $PostgresBin $connection
    Check 'exact_original_digest' (Test-RecoveryDatabaseSchema $PostgresBin $connection $captured).matched
    $null=Invoke-PostgresTool $PostgresBin pg_dump @('-w','--format=custom','--file',$dump,'-d',$database) $connection
    Reset-Fixture
    $actual=Test-RecoveryDatabaseSchema $PostgresBin $connection $captured
    Check 'actual_pg_dump_restore_between_shape_changes' ($actual.raw_schema_sha256 -cne $captured)
    Check 'known_parentheses_reconstruct_complete_captured_digest' ($actual.matched -and $actual.comparison -ceq 'continuation-request-id-and-shape-v1' -and $actual.reconstructed_sha256 -ceq $captured)
    Check 'restored_database_metadata_unchanged' ((Get-DatabaseMetadata $PostgresBin $connection) -ceq $metadata)
    Check 'restored_data_fingerprints_unchanged' (((Get-DatabaseFingerprints $PostgresBin $connection)|ConvertTo-Json -Compress) -ceq ($fingerprints|ConvertTo-Json -Compress))
    Check 'flat_snapshot_still_uses_original_digest_algorithm' ((Test-RecoveryDatabaseSchema $PostgresBin $connection $actual.raw_schema_sha256).comparison -ceq 'exact-pg-dump-v1')
    $flatSchema=Get-DatabaseSchemaText $PostgresBin $connection
    $flatDefinition="CHECK (((length(request_id) >= 1) AND (length(request_id) <= 128) AND (request_id ~ '^[A-Za-z0-9_-]+$'::text)))"
    $flatLine='    CONSTRAINT run_continuation_receipts_request_id_check '+$flatDefinition+','
    $nestedLine="    CONSTRAINT run_continuation_receipts_request_id_check CHECK ((((length(request_id) >= 1) AND (length(request_id) <= 128)) AND (request_id ~ '^[A-Za-z0-9_-]+$'::text))),"
    $duplicate=$flatSchema+"`n"+$flatLine
    $duplicateExpected=Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($flatSchema.Replace($flatLine,$nestedLine)+"`n"+$nestedLine)))
    Check 'duplicate_complete_constraint_lines_refused' (-not (Test-RecoverySchemaText $duplicate $duplicateExpected $flatDefinition).matched)
    Check 'unverified_catalog_definition_refused' (-not (Test-RecoverySchemaText $flatSchema $captured '').matched)
    Check 'case_or_regex_change_not_normalized' (-not (Test-RecoverySchemaText ($flatSchema.Replace('A-Za-z','a-zA-Z')) $captured $flatDefinition).matched)
    $cases=@(
        @{name='length_boundary';sql="ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_request_id_check; ALTER TABLE public.run_continuation_receipts ADD CONSTRAINT run_continuation_receipts_request_id_check CHECK(length(request_id)>=1 AND length(request_id)<=129 AND request_id ~ '^[A-Za-z0-9_-]+$');"},
        @{name='regex';sql="ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_request_id_check; ALTER TABLE public.run_continuation_receipts ADD CONSTRAINT run_continuation_receipts_request_id_check CHECK(length(request_id)>=1 AND length(request_id)<=128 AND request_id ~ '^[A-Za-z0-9_]+$');"},
        @{name='or_operator';sql="ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_request_id_check; ALTER TABLE public.run_continuation_receipts ADD CONSTRAINT run_continuation_receipts_request_id_check CHECK(length(request_id)>=1 AND length(request_id)<=128 OR request_id ~ '^[A-Za-z0-9_-]+$');"},
        @{name='not_operator';sql="ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_request_id_check; ALTER TABLE public.run_continuation_receipts ADD CONSTRAINT run_continuation_receipts_request_id_check CHECK(NOT(length(request_id)>=1 AND length(request_id)<=128 AND request_id ~ '^[A-Za-z0-9_-]+$')) NOT VALID;"},
        @{name='acl_revoke';sql="REVOKE SELECT ON public.run_continuation_receipts FROM `"$reader`";"},
        @{name='grant_option';sql="REVOKE GRANT OPTION FOR SELECT ON public.run_continuation_receipts FROM `"$reader`";"},
        @{name='grantor';sql="GRANT SELECT ON public.run_continuation_receipts TO `"$other`"; SET ROLE `"$reader`"; GRANT SELECT ON public.run_continuation_receipts TO `"$other`"; RESET ROLE;"},
        @{name='owner';sql="ALTER TABLE public.run_continuation_receipts OWNER TO `"$other`";"},
        @{name='other_constraint';sql='ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_counter_check;'},
        @{name='column';sql='ALTER TABLE public.run_continuation_receipts ADD COLUMN drift text;'},
        @{name='constraint_not_valid';sql="ALTER TABLE public.run_continuation_receipts DROP CONSTRAINT run_continuation_receipts_request_id_check; ALTER TABLE public.run_continuation_receipts ADD CONSTRAINT run_continuation_receipts_request_id_check CHECK(length(request_id)>=1 AND length(request_id)<=128 AND request_id ~ '^[A-Za-z0-9_-]+$') NOT VALID;"}
    )
    foreach($case in $cases){
        $null=Invoke-RecoverySQL $PostgresBin $connection $case.sql
        Check ($case.name+'_drift_refused') (-not (Test-RecoveryDatabaseSchema $PostgresBin $connection $captured).matched)
        Reset-Fixture
    }
    # A forged expected hash with a renamed table must not authorize the known
    # compatibility path: real catalog identity is an independent requirement.
    $null=Invoke-RecoverySQL $PostgresBin $connection 'ALTER TABLE public.run_continuation_receipts RENAME TO unrelated_receipts;'
    $renamed=Get-DatabaseSchemaText $PostgresBin $connection
    $forged=Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($renamed.Replace($flatLine,$nestedLine)))
    Check 'wrong_table_catalog_identity_refused' (-not (Test-RecoveryDatabaseSchema $PostgresBin $connection $forged).matched)
    $report.passed=$true
}finally{
    $null=Invoke-RecoverySQL $PostgresBin $admin ('DROP DATABASE IF EXISTS '+(Quote-PgIdentifier $database)+';')
    $null=Invoke-RecoverySQL $PostgresBin $admin ('DROP ROLE IF EXISTS '+(Quote-PgIdentifier $reader)+'; DROP ROLE IF EXISTS '+(Quote-PgIdentifier $other)+';')
    $report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding utf8
}
$report|ConvertTo-Json -Depth 5
