/*==============================================================================================================================================================================*/
/* Author						: Chris Ziros
/*	
/* Date			        		: 15 October 2026
/* 
/* Program		 	    		: at_risk_master_dataset.sas
/* 
/* Program Location    			: /sasdata/prod/worksafe/compensation/csmi/programs/
/*	
/* Description			 		: A master dataset capturing the at risk and do not contact details for a claim sourced from Salesforce data.	
/*
/* Input DWH tables	      		: 
									DW_CRM_CLAIM_XV
									DW_CLAIM_XV	
									DW_CRM_CLAIM_EVENT_XV
									DW_CRM_PERSON_PROFILE_XV
									DW_CRM_USER_XV
/*
/* Output SAS Datasets and locations :
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/at_risk_data_dv.sas7bdat	
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/at_risk_data_wv.sas7bdat
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/at_risk_data_mv.sas7bdat
/* Archive Location    				 : 	
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive/at_risk_data_yyyymmdd.sas7bdat
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive/at_risk_data_yyyymmdd.sas7bda
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive/at_risk_data_yyyymm.sas7bdat

/* Requested by						: CSMI (CRP) project team
/*
/* History:
/* Date       By  Description
/* --------   --  ---------------------------------------------------------------------------------------------------------------------------------------------------------------
/* 6/10/2026  CZ  Initial version
/* 20/10/2026 CZ  Added in Do Not Contact flag from the Person Profile object in Salesforce
/* 21/10/2026 CZ  Added in record type ID to the where clause. Removed the MAX aggregate for the total number of incidents

*/

** This snippet can automatically or manually set the environment where the program is being run;
** Once set, librefs and other 'write' or 'production' statements can be set conditionally, either to point to their normal production locations, or to safe development locations to allow development and testing;
** For automatic assignment, the following uses the presence of the _CLIENTAPP SAS system variable, which only exists when not being run on the SAS server and therefore likely run in SAS Enterprise Guide (EG).;
** If _CLIENTAPP exists, then the program is being run in SAS EG and therefore is likely under development, so the macro variable 'environment' is set to "dev", otherwise it is set to "prod".;

%if %symexist(_CLIENTAPP) %then
	%do;
		%let environment = dev;
		%put Environment: &environment;
	%end;
%else
	%do;
		%let environment = prod;
		%put Environment: &environment;
	%end;
run;

** Option to set manually if required. Initially commented out;
/*%let environment = dev;*/
/*%let environment = prod;*/
/********************************************************************************************************************************************/

/* You can force the program to create all three datasets - daily, weekly, monthly */
/* This is important if there are issues resulting in the datasets not being created during regular production runs */
/* Since the weekly dataset will only be created on Sunday and monthly will only be created if it hasn't already been created for the month, this will force all three datasets to be created at any time you run this */

/* To force all three datasets to update, set 'manual_update' to 'yes'. Otherwise keep it set to 'no' during regular run */ 
%let manual_update = no;
/*%let manual_update = yes;*/


** Condition to set librefs, based on value of environment variable;
%if (&environment eq prod) %then
	%do;
		libname csmi '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/';
		libname dv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive';
		libname wv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive';
		libname mv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive';

	%end;
%else
	%do;
		libname csmi '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/';
		libname dv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive';
		libname wv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive';
		libname mv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive';

	%end;

/************************************************************************************************************************************/
/* Set data warehouse connection																													*/
/************************************************************************************************************************************/
libname dwh ORACLE user = &dbuser orapw = &dbpass path = &dbpath preserve_col_names=yes dbindex=yes;

/************************************************************************************************************************************/
/* Date and snapshot setting 																										*/
/************************************************************************************************************************************/
%MONTHDT;
%INSURER;
%SNAPSHDT(M);
%logmsg(Monthly snapshot date:"&SNAPSHDT"D);
%SCMF;
%MAKEVAR(EOM("&SNAPSHDT"D, 0) FORMAT = DATE9., eom);
%EOMDATES(&eom);
%logmsg(&mmmyyyy);
%logmsg(&yyyymm);
%logmsg(&yyyymmdd);
%snapshdt(w, FORMAT = YYMMDDN8.);
%let weeklydt = &SNAPSHDT.;
%logmsg(weekly snapshot date:&weeklydt.);
%snapshdt(d, FORMAT = YYMMDDN8.);
%logmsg(daily snapshot date:&SNAPSHDT.);

/************************************************************************************************************************************/
/* Check for start of the week																										*/
/************************************************************************************************************************************/
%let wkday = %sysfunc(weekday(%sysfunc(today())));
%logmsg(&wkday.);

%let day_name = %sysfunc(putn(%sysfunc(today()), downame.));
%put &=day_name;
%logmsg(&day_name.);


/************************************************************************************************************************************/
/* Check for start of the month																										*/
/************************************************************************************************************************************/
%if 
	%sysfunc(exist(mv_arch.at_risk_data_&yyyymm.)) %then
	%do;
		%let mthupdate=YES;
	%end;
%else
	%do;
		%let mthupdate=No;
	%end;

%logmsg(&mthupdate);

/************************************************************************************************************************************/
/* Macro to create Master datasets																									*/
/************************************************************************************************************************************/
%macro create_dataset(view);
	%logmsg(&view);

	/*========================================*/
	/* Create claim datasets                  */
	/*========================================*/
	proc sql;
		create table CSMI_CLAIMS as 
			select	clm.CLAIM_ID 											LABEL = 'Claim id'
				,	clm.AFFLICTION_DT 										LABEL = 'Affliction Date'	
				,	clm.AFFLICTION_NATURE_CD 								LABEL = 'Affliction Nature Code'
				,	clm.CLAIMANT_ID 										LABEL = 'Claimant ID'	
				,	clm.CURR_MANAGING_INSURER_CD 	AS 	AGENT 				LABEL = 'Current Managing Insurer Code'
				,	clm.CURR_MANAGING_ORGN_ID 								LABEL = 'Current Managing Organisation Identifier'
				,	clm.CURR_MANAGING_POSITION_ID 							LABEL = 'Current Managing Position Identifier'
				,	clm.INSURER_BRANCH_CD 									LABEL = 'Insurer Branch Code'
				,	clm.INSURER_RECEIVED_DT 								LABEL = 'Insurer Received Date'
				,	crm_clm.CLAIM_ID              	AS 	SF_CLAIM_ID 		LABEL = 'Salesforce Claim Id'
				,	crm_clm.STAGE_TX              	AS 	SF_CLAIM_STAGE_TX 	LABEL = 'Salesforce Stage Text'
			from		DWH.DW_CRM_CLAIM_&view.				crm_clm
			LEFT JOIN	DWH.DW_CLAIM_&view.					clm
			ON			crm_clm.acction_clm_nb = clm.claim_id
			WHERE 		crm_clm.is_deleted_fl='N' /*remove deleted records*/
			ORDER BY 	clm.CLAIM_ID, crm_clm.CLAIM_ID;
		%datepart(CSMI_CLAIMS);
	;

	/*===========================================================================*/
	/* Extract the at risk details from the Personal Profile table in Salesforce */
	/*===========================================================================*/
	PROC SQL;
		CREATE TABLE PERSON_PROFILE_DETAILS as 
			SELECT 	PP.CLAIM_ID 					AS SF_CLAIM_ID 			LABEL = 'Claim id'
				,	PP.RISK_ID												LABEL = 'Risk ID'
				,	PP.MAP_ID												LABEL = 'Management Action Plan ID. Used to join to the Recommendation object in Salesforce'
				,	PP.TYPE_1_TX					AS risk_type			LABEL = 'The risk type identified for the claimant'
				,	PP.SUB_TY						AS risk_subtype			LABEL = 'The risk sub type identified for the claimant'
				,	PP.LAST_MODIFIED_DT_TM 									LABEL = 'The date the risk flag was last modified'
				,	PP.DATE_OF_REVIEW_DT 									LABEL = 'The review date for the risk'
				,	PP.STATUS_TX											LABEL = 'The status of the risk flag'
				,	PP.TOTAL_INCIDENTS_NB 			AS TOTAL_INCIDENTS_NB	LABEL = 'The total number of incidents recorded against the claim'
				,	PP.ASAACTION_TX 				AS ALT_SERVICES_ARRANGEMENT		LABEL = 'Alternate service arrangement action against the claim'
				,	PP.START_DT 											LABEL = 'Alternate service arrangement action start date'
				,	PP.END_DT 												LABEL = 'Alternate service arrangement action end date'
				,	PP.DATE_OF_REVIEW_DT 									LABEL = 'Alternate service arrangement action review date'
				,	PP.CREATED_DT_TM 										LABEL = 'The date the risk incident occurred'
				,	PP.PERSON_ID 											LABEL = 'Person identification number'
				,	PP.IS_PRHBTD_FRM_CNTCTNG_FL		AS DO_NOT_CONTACT_FLAG	LABEL = 'Has the claim been flagged as do not contact'
				,	USER.NAME 						AS USER_IDENTIFIED_THE_RISK	LABEL = 'User who identified the risk'
				,	CRM_CLM.CLAIM_ID
				,	CRM_CLM.AFFLICTION_DT
				,	CRM_CLM.AFFLICTION_NATURE_CD	
				,	CRM_CLM.CLAIMANT_ID
				,	CRM_CLM.AGENT
				,	CRM_CLM.CURR_MANAGING_ORGN_ID
				,	CRM_CLM.CURR_MANAGING_POSITION_ID
				,	CRM_CLM.INSURER_BRANCH_CD
				,	CRM_CLM.INSURER_RECEIVED_DT
				,	CRM_CLM.SF_CLAIM_STAGE_TX

			FROM 		DWH.DW_CRM_PERSON_PROFILE_&view.	            PP
			LEFT JOIN	CSMI_CLAIMS                     				CRM_CLM
			ON 			PP.CLAIM_ID = CRM_CLM.sf_CLAIM_ID
			LEFT JOIN	DWH.DW_CRM_USER_&view.					USER
			ON			PP.CREATED_BY_ID = USER.USER_ID

			/* Only include claims with an at risk flag */
			WHERE PP.TYPE_1_TX ^= '' and PP.RECORD_ID = '012Mq000005IMx0IAG'
;

		/* Join in the EVENT details */
	PROC SQL;
		CREATE TABLE AT_RISK_DATA AS
			SELECT	PP.*
				,	EVENT.EVENT_STATUS_TX 						LABEL = 'The status of the recorded risk event'
				,	EVENT.EMERGENCY_HOSPITALISATION_TX 			LABEL = 'Person moved to emergency hospitalisation regarding the incident'
				,	EVENT.DUTY_OF_CARE_TX 						LABEL = 'Person who was notified of the risk incident'
				,	EVENT.HOW_WAS_THE_RISK_NOTIFIED_TX 			LABEL = 'Method of notifying the risk incident'
			FROM 		PERSON_PROFILE_DETAILS 					PP
			LEFT JOIN	DWH.DW_CRM_CLAIM_EVENT_&view.			EVENT
			ON			PP.PERSON_ID = EVENT.RISK_ID 
		;



%mend create_dataset;

/************************************************************************************************************************************/
/* Macro to write Master datasets																									*/
/************************************************************************************************************************************/
%macro write_datasets(lib, snap);
	%logmsg(&lib.);

	data &lib..at_risk_data_&snap;
		set AT_RISK_DATA;
	run;

%mend write_datasets;

/********************************************************************************/
/* Below logic is to determine which datasets to create: Daily, Weekly, Monthly	*/
/********************************************************************************/

/* Daily - runs every day without exception*/

/* Create the dataset using the daily view */
%create_dataset(dv);

/* Save to the master datasets folder for production use */
%write_datasets(lib=csmi, snap=dv);

/* Save a copy in the archive folder with the snapshot date appended */
%write_datasets(lib=dv_arch, snap=&SNAPSHDT.);


/* Weekly */
/* Runs on a sunday (wkday macro is set to 1 for Sunday) */
%if (&wkday.= 1) %then
	%do;
		/* Create the dataset using the weekly view */
		%create_dataset(wv);

		/* Save to the master datasets folder for production use */
		%write_datasets(lib=csmi, snap=wv );

		/* Save a copy in the archive folder with the snapshot date appended */
		%write_datasets(lib=wv_arch, snap=&weeklydt.);
	%end;
%else
	%do;
		%logmsg("Weekly dataset not created. The weekly dataset will only be created on a Sunday. Today is &day_name");
	%end;

/* Monthly - when it's the first run of the month or the historic snapshot doesn't exist */
%if (&mthupdate eq No) %then
	%do;
		/* Create the dataset using the monthly view */
		%create_dataset(mv);

		/* Save to the master datasets folder for production use */
		%write_datasets(lib=csmi, snap=mv);

		/* Save a copy in the archive folder with the snapshot date appended */
		%write_datasets(lib=mv_arch, snap=&yyyymm.);
	%end;
%else
	%do;
		%logmsg('Monthly dataset not created as it already has been created for &mmmyyyy');
	%end;

/* The macro below will force the weekly and monthly datasets to be created at the time you run this program. Daily datasets will be created regardless, so this is not added to the macro below */
%macro force_update();

	/* run weekly */
	%create_dataset(wv);
	%write_datasets(lib=csmi, snap=wv );
	%write_datasets(lib=wv_arch, snap=&weeklydt.);

	/* run monthly */
	%create_dataset(mv);
	%write_datasets(lib=csmi, snap=mv);
	%write_datasets(lib=mv_arch, snap=&yyyymm.);
%mend force_update;

%if (&manual_update eq yes) %then
	%do;
		%logmsg('Forcing the weekly and monthly datasets to run on &day_name');
		%force_update;
	%end;
