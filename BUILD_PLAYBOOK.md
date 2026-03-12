build_spec_version: 1
updated_utc: 2026-03-09T00:00:00Z
module:
  name: Morpheus.OpenApi
  version: 8.0.13
  source_openapi: openapi.yaml
  generator: morpheus-powershell/scripts/Generate-MorpheusModule.ps1
  outputs:
    - morpheus-powershell/Morpheus.OpenApi.psm1
    - morpheus-powershell/Morpheus.OpenApi.psd1
constraints:
  generation:
    - full_endpoint_coverage: true
    - naming_style: friendly_resource_names
    - avoid_numeric_suffixes_unless_required: true
  targeting:
    - multi_connection_support: true
    - require_morpheus_for_methods_when_multi_connected:
        - POST
        - PUT
        - DELETE
    - optional_morpheus_for_get: true
    - optional_morpheus_when_single_connection: true
  auth:
    - api_token
    - credential
    - username_secure_password
    - username_plaintext_password
  parameters:
    - all_path_params_positional_in_path_order: true
    - request_body_schema_fields_exposed_as_flags: true
    - prompt_labels_flag_style_not_dotted_paths: true
    - dynamic_live_argument_completion_for_common_id_flags: true
    - id_like_parameters_support_valuefrompipelinebypropertyname: true
  request_body:
    - required_fields_prompted_interactively: true
    - config_field_prompt_mode: key_then_value_loop_until_blank_key
    - array_object_fields_must_validate_item_required_keys: true
    - array_object_missing_item_keys_prompted_cleanly_by_item_index: true
    - config_values_parsed_as_typed_scalars:
        - bool
        - integer
        - float
        - null
        - string
  output:
    - default_shaping_enabled: true
    - property_selector_flag: Property
    - detailed_flag: Detailed
    - column_profiles_file: morpheus-powershell/Morpheus.OpenApi.ColumnProfiles.psd1
    - typed_object_layer_with_pstypenames: true
  async:
    - task_helpers_exported:
        - Get-MorpheusTask
        - Wait-MorpheusTask
    - wait_supports_inputobject_and_taskid: true
    - wait_uses_polling_with_timeout: true
    - task_status_normalization_present: true
  paging:
    - auto_paging_default_for_get_with_max_offset: true
    - default_page_size: 25
    - manual_max_offset_override: true
    - disable_auto_paging_flag: NoPaging
  preview:
    - curl_flag: Curl
    - scrub_flag: Scrub
    - curl_does_not_execute: true
    - scrub_only_masks_bearer_token: true
  packaging:
    - installer_builder_script: morpheus-powershell/scripts/New-MorpheusInstallerExe.ps1
    - installer_name_format: Morpheus.OpenApi-{ModuleVersion}-Setup.exe
    - installer_version_must_match_manifest_moduleversion: true
    - installer_supports_authenticode_signing: true
    - signer_inputs:
        - CertificateThumbprint
        - PfxPath
  safety:
    - remove_cmdlets_shouldprocess: true
    - post_put_patch_shouldprocess_parity: true
  help:
    - all_endpoint_cmdlets_must_emit_comment_help: true
    - include_sections:
        - SYNOPSIS
        - DESCRIPTION
        - PARAMETER
        - EXAMPLE
        - OUTPUTS
    - synopsis_description_source: openapi_summary_description
    - response_example_source: openapi_response_example_first_available
rebuild_procedure:
  - step: set_location
    path: morpheus-powershell/scripts
  - step: run
    command: ./Generate-MorpheusModule.ps1
  - step: import
    command: Import-Module "..\\Morpheus.OpenApi.psd1" -Force
  - step: package
    command: ./New-MorpheusInstallerExe.ps1 -Force
  - step: verify
    checks:
      - name: endpoint_count
        command: (Get-Command -Module Morpheus.OpenApi).Count
      - name: curl_scrub_on_all_endpoints
        command: |
          $session=@('Connect-Morpheus','Disconnect-Morpheus','Get-MorpheusConnection','Set-MorpheusDefault','New-MorpheusKeyValueMap')
          $ops=Get-Command -Module Morpheus.OpenApi | Where-Object { $session -notcontains $_.Name }
          (@($ops | Where-Object { -not $_.Parameters.ContainsKey('Curl') -or -not $_.Parameters.ContainsKey('Scrub') }).Count) -eq 0
      - name: instance_body_flags
        command: |
          $c=Get-Command New-MorpheusInstance
          $c.Parameters.ContainsKey('PlanId') -and $c.Parameters.ContainsKey('ZoneId') -and $c.Parameters.ContainsKey('Copies') -and $c.Parameters.ContainsKey('LayoutSize')
      - name: help_sections_present
        command: |
          $h=Get-Help New-MorpheusInstance -Full
          ($h.Synopsis -ne $null) -and ($h.description -ne $null) -and ($h.parameters -ne $null) -and ($h.examples -ne $null)
      - name: async_task_cmdlets_present
        command: |
          $c1=Get-Command Get-MorpheusTask -ErrorAction SilentlyContinue
          $c2=Get-Command Wait-MorpheusTask -ErrorAction SilentlyContinue
          ($null -ne $c1) -and ($null -ne $c2)
      - name: wait_task_supports_inputobject
        command: |
          $w=Get-Command Wait-MorpheusTask
          $w.Parameters.ContainsKey('InputObject') -and $w.Parameters.ContainsKey('TaskId')
      - name: installer_exe_versioned
        command: |
          $m=Import-PowerShellDataFile ..\Morpheus.OpenApi.psd1
          Test-Path (Join-Path ..\dist ("Morpheus.OpenApi-{0}-Setup.exe" -f $m.ModuleVersion))
      - name: installer_builder_signing_params_present
        command: |
          $c=Get-Command .\New-MorpheusInstallerExe.ps1
          $c.Parameters.ContainsKey('CertificateThumbprint') -and $c.Parameters.ContainsKey('PfxPath')
instruction_log:
  - date: 2026-03-06
    change: initial_complete_module_generation_and_multi_target_auth_support
  - date: 2026-03-06
    change: friendly_naming_get_consolidation_output_shaping_paging_remove_confirmation
  - date: 2026-03-06
    change: positional_path_params_for_all_endpoints
  - date: 2026-03-06
    change: curl_preview_and_scrub_added
  - date: 2026-03-06
    change: scrub_behavior_limited_to_bearer_token_only
  - date: 2026-03-06
    change: key_value_config_entry_model_and_body_field_flags_with_clean_prompts
  - date: 2026-03-06
    change: comment_based_help_generation_from_openapi_with_examples
  - date: 2026-03-06
    change: array_object_item_requirement_enforcement_added_for_body_fields_across_endpoints
  - date: 2026-03-06
    change: relocate_module_workspace_to_git_morpheus-powershell
  - date: 2026-03-09
    change: dynamic_id_argument_completers_and_non_delete_whatif_parity
  - date: 2026-03-09
    change: typed_object_layer_and_pipeline_first_identity_binding
  - date: 2026-03-09
    change: async_task_polling_cmdlets_get_morpheus_task_and_wait_morpheus_task
  - date: 2026-03-09
    change: executable_installer_workflow_added_via_iexpress
  - date: 2026-03-09
    change: executable_installer_optional_authenticode_signing_added
maintenance_rule:
  on_new_user_instruction:
    - update.constraints
    - update.rebuild_procedure_or_verification_if_needed
    - append.instruction_log
    - regenerate_module
    - validate_no_generator_errors
