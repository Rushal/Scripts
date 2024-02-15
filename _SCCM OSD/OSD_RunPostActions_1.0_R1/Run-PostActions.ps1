param(
    [switch]$osd
)

Start-Transcript -Path "C:\Windows\Temp\Run-PostActions_$((Get-date).tostring("yyyy-MM-dd_HH-mmm-ss")).log"
if ($osd) {
    # Schedule Task to make sure service is running
    $taskName = "_FreshImage"
    $trigger = New-ScheduledTaskTrigger -At (get-date).AddMinutes(2) -Once
    $argument = "-noprofile -executionpolicy bypass -File C:\Windows\Temp\Run-PostActions.ps1"
    $action = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory C:\Windows\Temp -Argument $argument
    $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Settings $settings -Description "Runs after a PC is imaged and deletes itself" -User "NT AUTHORITY\SYSTEM" -RunLevel Highest

    # Get the Scheduled Task
    $task = Get-ScheduledTask -TaskName $taskName

    # Update to make sure it deletes itself
    $task.Author = 'IT Support'
    $task.Triggers[0].StartBoundary = [DateTime]::Now.AddMinutes(3).ToString("yyyy-MM-dd'T'HH:mm:ss")
    $task.Triggers[0].EndBoundary = [DateTime]::Now.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss")
    $task.Settings.AllowHardTerminate = $True
    $task.Settings.DeleteExpiredTaskAfter = 'PT0S'
    $task.Settings.ExecutionTimeLimit = 'PT1H'
    $task.Settings.volatile = $False

    # Save tweaks to the Scheduled Task
    $task | Set-ScheduledTask

    # GPUpdate
    Start-Process cmd.exe -ArgumentList "/c echo n | gpupdate /force /wait:0" -Wait

    # Try to get certs
    Start-Process certutil.exe -ArgumentList "-pulse" -Wait

    # Cleanup SMSTS folder
    Remove-Item -Path "C:\_SMSTaskSequence" -Recurse -Force -ErrorAction SilentlyContinue

    # Run SCCM Machine Eval
    Restart-Service -Name "SMS Agent Host" -Force
    Start-Sleep -Seconds 30
    ([wmiclass]'root\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000021}')
    ([wmiclass]'root\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000022}')

    # Reboot
    Start-Sleep -Seconds 15
    Stop-Transcript
    Restart-Computer -Force
}
else {
    # Run SCCM Machine Eval
    Restart-Service -Name "SMS Agent Host" -Force
    Start-Sleep -Seconds 30
    ([wmiclass]'root\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000021}')
    ([wmiclass]'root\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000022}')

    Start-Sleep -Seconds 15
    Unregister-ScheduledTask -TaskName "_FreshImage" -Confirm:$false
    
    # Reboot
    Stop-Transcript
    Restart-Computer -Force
}