$result = ""
$testResult = ""
$resultArr = @()

$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$noClient = $true
		$noServer = $true
		foreach ( $vmData in $allVMData )
		{
			if ( $vmData.RoleName -imatch "client" )
			{
				$clientVMData = $vmData
				$noClient = $false
			}
			elseif ( $vmData.RoleName -imatch "server" )
			{
				$noServer = $fase
				$serverVMData = $vmData
			}
		}
		if ( $noClient )
		{
			Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ( $noServer )
		{
			Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		LogMsg "CLIENT VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.PublicIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		LogMsg "SERVER VM details :"
		LogMsg "  RoleName : $($serverVMData.RoleName)"
		LogMsg "  Public IP : $($serverVMData.PublicIP)"
		LogMsg "  SSH Port : $($serverVMData.SSHPort)"

		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

		#endregion

		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile	
		Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
		foreach ( $param in $currentTestData.TestParameters.param)
		{
            if ($param -imatch "pingIteration")
            {
                $pingIteration=$param.Trim().Replace("pingIteration=","")
            }
			Add-Content -Value "$param" -Path $constantsFile
		}
		LogMsg "constanst.sh created successfully..."
		LogMsg (Get-Content -Path $constantsFile)
		#endregion

		
		#region EXECUTE TEST
		$myString = @"
cd /root/
./perf_lagscope.sh &> lagscopeConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@
		Set-Content "$LogDir\StartLagscopeTest.sh" $myString
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\Testscripts\Linux\azuremodules.sh,.\Testscripts\Linux\perf_lagscope.sh,.\$LogDir\StartLagscopeTest.sh" -username "root" -password $password -upload
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartLagscopeTest.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 lagscopeConsoleLogs.txt"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "lagscope-n$pingIteration-output.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
		
		$testSummary = $null
		$lagscopeReportLog = Get-Content -Path "$LogDir\lagscope-n$pingIteration-output.txt"
        LogMsg $lagscopeReportLog

            try
            {
                $matchLine= (Select-String -Path "$LogDir\lagscope-n$pingIteration-output.txt" -Pattern "Average").Line
                $minimumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[1]
                $maximumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[3]
                $averageLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[5]

                $resultSummary +=  CreateResultSummary -testResult $minimumLat -metaData "Minimum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                $resultSummary +=  CreateResultSummary -testResult $maximumLat -metaData "Maximum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
                $resultSummary +=  CreateResultSummary -testResult $averageLat -metaData "Average Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
            catch
            {
                $resultSummary +=  CreateResultSummary -testResult "Error in parsing logs." -metaData "LAGSCOPE" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
		#endregion

		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
			LogMsg "Contests of summary.log : $testSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
		
		LogMsg "Uploading the test results.."
		$dataSource = $xmlConfig.config.$TestPlatform.database.server
		$user = $xmlConfig.config.$TestPlatform.database.user
		$password = $xmlConfig.config.$TestPlatform.database.password
		$database = $xmlConfig.config.$TestPlatform.database.dbname
		$dataTableName = $xmlConfig.config.$TestPlatform.database.dbtable
		$TestCaseName = $xmlConfig.config.$TestPlatform.database.testTag
		if ($dataSource -And $user -And $password -And $database -And $dataTableName) 
		{
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
			
			#$TestCaseName	= "LINUX-NEXT-UPSTREAM-TEST"
			if ( $UseAzureResourceManager )
			{
				$HostType	= "Azure-ARM"
			}
			else
			{
				$HostType	= "Azure"
			}
			$HostBy	= ($xmlConfig.config.$TestPlatform.General.Location).Replace('"','')
			$HostOS	= cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
			$GuestOSType	= "Linux"
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
			$GuestSize = $clientVMData.InstanceSize
			$KernelVersion	= cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
			$IPVersion = "IPv4"
			$ProtocolType = "TCP"
			if($EnableAcceleratedNetworking)
			{
				$DataPath = "SRIOV"
			}
			else
			{
				$DataPath = "Synthetic"    
			}
			$connectionString = "Server=$dataSource;uid=$user; pwd=$password;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

			$SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,DataPath,MaxLatency_us,AverageLatency_us,MinLatency_us,Latency95Percentile_us,Latency99Percentile_us) VALUES "
            
            #Percentile Values are not calculated yet. will be added in future.
            $Latency95Percentile_us = 0
            $Latency99Percentile_us = 0

            $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','$ProtocolType','$DataPath','$maximumLat','$averageLat','$minimumLat','$Latency95Percentile_us','$Latency99Percentile_us'),"

			$SQLQuery = $SQLQuery.TrimEnd(',')
			LogMsg $SQLQuery
			$connection = New-Object System.Data.SqlClient.SqlConnection
			$connection.ConnectionString = $connectionString
			$connection.Open()

			$command = $connection.CreateCommand()
			$command.CommandText = $SQLQuery
			$result = $command.executenonquery()
			$connection.Close()
			LogMsg "Uploading the test results done!!"
		}
		else
		{
			LogMsg "Invalid database details. Failed to upload result to database!"
		}
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "LAGSCOPE RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
