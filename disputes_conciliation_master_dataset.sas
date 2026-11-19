/*==============================================================================================================================================================================*/
/* Author						: Nathan McGuinness
/*
/* Date			        		: 20 November 2026
/*
/* Program		 	    		: disputes_conciliation_master_dataset.sas
/*
/* Program Location    			: /sasdata/prod/worksafe/compensation/csmi/programs/   (TO CONFIRM)
/*
/* Description			 		: Master datasets for Disputes and Conciliation, combining Salesforce (DW_CRM_*) and legacy ACCtion (DW_*) data.
/*								  The main dataset has ONE ROW PER OUTCOME, with the public complaint (dispute), claim, conciliation and
/*								  outcome owner attached. One-to-many detail (tasks, interactions, attendees, documents, cases, invoice lines)
/*								  is written to separate child datasets so that the main dataset is never duplicated by those joins.
/*
/* Input DWH tables	      		:
									DW_CRM_OUTCOME_XV
									DW_CRM_PUBLIC_COMPLAINT_XV
									DW_CRM_CLAIM_XV
									DW_CLAIM_ALL_XV
									DW_CONCILIATION_XV
									DW_CRM_USER_XV
									DW_CRM_OMNI_ASSESSMENT_TASK_XV
									DW_CRM_TASK_XV
									DW_CRM_INTERACTION_XV
									DW_CRM_INTERACTION_LINK_XV
									DW_CRM_INTERACTION_SUMMARY_XV
									DW_CRM_INTERACTION_ATTENDEE_XV
									DW_CRM_CONTENT_DOC_REF_LINK_XV
									DW_CRM_CONTENT_DCMNT_RFRNCE_XV
									DW_CRM_CASE_XV
									DW_SERVICE_INVOICE_LINE_XV
									(XV = DV, WV or MV, set by the view macro variable)
/*
/* Output SAS Datasets (each in _dv, _wv and _mv versions) :
									dc_outcome_data      - MAIN: one row per outcome
									dc_task_data         - one row per omni assessment task (with Salesforce task)
									dc_interaction_data  - one row per interaction linked to an outcome (with interaction summary)
									dc_attendee_data     - one row per interaction attendee
									dc_document_data     - one row per document linked to a record (with document reference)
									dc_case_data         - one row per Salesforce case (with Salesforce claim)
									dc_invoice_data      - one row per service invoice line
/* Output location     			: /sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/   (TO CONFIRM)
/* Archive Location    			:
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive/dc_xxx_data_yyyymmdd.sas7bdat
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive/dc_xxx_data_yyyymmdd.sas7bdat
									/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive/dc_xxx_data_yyyymm.sas7bdat
/*
/* Notes:
/*   Salesforce-only fields (red in the ERD, no DWH name yet) are NOT included. Add them here once DWH names are assigned.
/*
/* History:
/* Date       By  Description
/* --------   --  ---------------------------------------------------------------------------------------------------------------------------------------------------------------
/* 20/11/2026 NM  Initial version, based on at_risk_master_dataset.sas

*/

** This snippet can automatically or manually set the environment where the program is being run;
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

/* To force all three datasets (daily, weekly, monthly) to update, set 'manual_update' to 'yes'. Otherwise keep it set to 'no' during regular run */
%let manual_update = no;
/*%let manual_update = yes;*/


** Condition to set librefs, based on value of environment variable;
%if (&environment eq prod) %then
	%do;
		libname dnc    '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/';
		libname dv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive';
		libname wv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive';
		libname mv_arch '/sasdata/prod/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive';
	%end;
%else
	%do;
		libname dnc    '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/';
		libname dv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/daily_archive';
		libname wv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/weekly_archive';
		libname mv_arch '/sasdata/dev/worksafe/compensation/Claims_Sf_Masterdatasets/monthly_archive';
	%end;

/************************************************************************************************************************************/
/* Set data warehouse connection																									*/
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
	%sysfunc(exist(mv_arch.dc_outcome_data_&yyyymm.)) %then
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

	/*=====================================================================================*/
	/* MAIN dataset: one row per outcome                                                   */
	/* Outcome -> Public Complaint -> Salesforce Claim -> Legacy Claim -> Conciliation     */
	/*=====================================================================================*/
	proc sql;
		create table DC_OUTCOME_DATA as
			select	/* Outcome */
					oc.OUTCOME_ID 											LABEL = 'Outcome id'
				,	oc.PARENT_TX 											LABEL = 'Parent'
				,	oc.PUBLIC_COMPLAINT_ID 									LABEL = 'Public complaint id'
				,	oc.OR_UPDATE_TY 										LABEL = 'Or update type'
				,	oc.DECISION_TY 											LABEL = 'Decision type'
				,	oc.DECISION_REASON_TX 									LABEL = 'Decision reason'
				,	oc.STATUS_TX 				AS OUTCOME_STATUS_TX 		LABEL = 'Outcome status'
				,	oc.STAGE_TX 				AS OUTCOME_STAGE_TX 		LABEL = 'Outcome stage'
				,	oc.CONCILIATION_OUTCOME_TX 								LABEL = 'Conciliation outcome'
				,	oc.CREATED_DT_TM 			AS OUTCOME_CREATED_DT_TM 	LABEL = 'Outcome created date time'
				,	oc.OWNER_ID 				AS OUTCOME_OWNER_ID 		LABEL = 'Outcome owner id'
					/* Outcome owner */
				,	usr.USER_NM 				AS OUTCOME_OWNER_NM 		LABEL = 'Outcome owner name'
				,	usr.USER_ROLE_ID 			AS OUTCOME_OWNER_ROLE_ID 	LABEL = 'Outcome owner role id'
				,	usr.CREATED_DT_TM 			AS OUTCOME_OWNER_CREATED_DT_TM	LABEL = 'Outcome owner user created date time'
					/* Public complaint (dispute) */
				,	pc.DISPUTE_ID_TX 										LABEL = 'Dispute id'
				,	pc.TYPE_OF_DISPUTE_TX 									LABEL = 'Type of dispute'
				,	pc.DATEOF_DISPUTE_DT 									LABEL = 'Date of dispute'
				,	pc.ACT_ID_TX 				AS DISPUTE_ACT_ID_TX 		LABEL = 'Dispute Act id'
				,	pc.ACT_REF_CD_TX 			AS DISPUTE_ACT_REF_CD_TX 	LABEL = 'Dispute Act reference code'
				,	pc.ARBITRATION_REF_NO_TX 								LABEL = 'Arbitration reference number'
				,	pc.EXTERNAL_ID_TX 										LABEL = 'External id'
				,	pc.DISPUTE_DETAILS_TX 									LABEL = 'Dispute details'
					/* Salesforce claim */
				,	crm_clm.CLAIM_ID 			AS SF_CLAIM_ID 				LABEL = 'Salesforce Claim Id'
				,	crm_clm.ACCTION_CLM_NB 									LABEL = 'ACCtion claim number'
				,	crm_clm.INSURER_RECEIVED_DT AS SF_INSURER_RECEIVED_DT 	LABEL = 'Salesforce Insurer Received Date'
				,	crm_clm.MANAGING_INSURER_NM 							LABEL = 'Managing Insurer Name'
					/* Legacy ACCtion claim */
				,	clm.CLAIM_ID 											LABEL = 'Claim id'
				,	clm.CLAIMANT_ID 										LABEL = 'Claimant ID'
				,	clm.CLAIMANT_FIRST_GIVEN_NM 							LABEL = 'Claimant first given name'
				,	clm.CLAIMANT_FAMILY_NM 									LABEL = 'Claimant family name'
				,	clm.AFFLICTION_NATURE_CD 								LABEL = 'Affliction Nature Code'
				,	clm.AFFLICTION_DT 										LABEL = 'Affliction Date'
				,	clm.CURR_MANAGING_ORGN_ID 								LABEL = 'Current Managing Organisation Identifier'
				,	clm.INSURER_RECEIVED_DT 								LABEL = 'Insurer Received Date'
					/* Conciliation */
				,	conc.CLAIM_REVIEW_TYPE_NB 								LABEL = 'Claim review type number (links to dispute id)'
				,	conc.CLAIM_REVIEW_TYPE_CD 								LABEL = 'Claim review type code'
				,	conc.CLAIM_REVIEW_START_DT 								LABEL = 'Claim review start date'
				,	conc.CLAIM_REVIEW_END_DT 								LABEL = 'Claim review end date'
				,	conc.CLAIM_REVIEW_STS_REASON_CD 						LABEL = 'Claim review status reason code'
				,	conc.NOTICE_OF_INSR_DECISION_DT 						LABEL = 'Notice of insurer decision date'
				,	conc.INSURER_CD 			AS CONC_INSURER_CD 			LABEL = 'Conciliation insurer code'
				,	conc.ACT_SECTION_CD 									LABEL = 'Act section code'
				,	conc.ACT_REFERENCE_ID 									LABEL = 'Act reference id'
				,	conc.ACT_ID 				AS CONC_ACT_ID 				LABEL = 'Conciliation Act id'
				,	conc.COHORT_LEVEL_1_CD 									LABEL = 'Cohort level 1 code'
				,	conc.COHORT_LEVEL_2_CD 									LABEL = 'Cohort level 2 code'
			from		DWH.DW_CRM_OUTCOME_&view.				oc
			LEFT JOIN	DWH.DW_CRM_PUBLIC_COMPLAINT_&view.		pc
			ON			oc.PUBLIC_COMPLAINT_ID = pc.PUBLIC_COMPLAINT_ID
			LEFT JOIN	DWH.DW_CRM_CLAIM_&view.					crm_clm
			ON			pc.CLAIM_ID = crm_clm.CLAIM_ID
			LEFT JOIN	DWH.DW_CLAIM_ALL_&view.					clm
			ON			crm_clm.ACCTION_CLM_NB = clm.CLAIM_ID
			LEFT JOIN	DWH.DW_CONCILIATION_&view.				conc
			ON			clm.CLAIM_ID = conc.CLAIM_ID
			AND			strip(conc.CLAIM_REVIEW_TYPE_NB) = strip(pc.DISPUTE_ID_TX)
			LEFT JOIN	DWH.DW_CRM_USER_&view.					usr
			ON			oc.OWNER_ID = usr.USER_ID
			ORDER BY 	oc.OUTCOME_ID;
	quit;
	%datepart(DC_OUTCOME_DATA);

	/* Row count check: main dataset must have exactly one row per outcome. If not, one of the joins is duplicating rows */
	proc sql noprint;
		select count(*) into :n_main trimmed from DC_OUTCOME_DATA;
		select count(*) into :n_outcome trimmed from DWH.DW_CRM_OUTCOME_&view.;
	quit;
	%if (&n_main ne &n_outcome) %then
		%do;
			%put WARNING: DC_OUTCOME_DATA (&view) has &n_main rows but DW_CRM_OUTCOME_&view has &n_outcome rows. A join is duplicating outcomes - check conciliation and claim joins.;
		%end;
	%else
		%do;
			%logmsg(Row count check passed for &view: &n_main rows);
		%end;

	/*=====================================================================================*/
	/* CHILD: Omni assessment tasks (with Salesforce task)                                 */
	/* Omni task Outcome_id -> Outcome ; Omni Task_relation_id = Task What_id              */
	/*=====================================================================================*/
	proc sql;
		create table DC_TASK_DATA as
			select	om.OMNI_ASSESSMENT_TASK_ID 								LABEL = 'Omni assessment task id'
				,	om.OUTCOME_ID 											LABEL = 'Outcome id'
				,	om.TASK_RELATION_ID 									LABEL = 'Task relation id'
				,	om.OMNI_ASSESSMENT_TASK_NAME 							LABEL = 'Omni assessment task name'
				,	om.CREATED_DT_TM 			AS OMNI_CREATED_DT_TM 		LABEL = 'Omni assessment task created date time'
				,	om.STATUS_CD 				AS OMNI_STATUS_CD 			LABEL = 'Omni assessment task status code'
				,	om.STATUS_TX 				AS OMNI_STATUS_TX 			LABEL = 'Omni assessment task status'
				,	om.OMNI_PROCESS_ID 										LABEL = 'Omni process id'
				,	om.IS_ADVERSE_FL 										LABEL = 'Is adverse flag'
				,	om.DECISION_TX 											LABEL = 'Decision'
				,	om.OUTCOME_STAGE_TX 		AS OMNI_OUTCOME_STAGE_TX 	LABEL = 'Omni outcome stage'
				,	tsk.TASK_ID 											LABEL = 'Task id'
				,	tsk.WHAT_ID 											LABEL = 'Task what id'
				,	tsk.SUBJECT_TX 											LABEL = 'Task subject'
				,	tsk.STATUS_TX 				AS TASK_STATUS_TX 			LABEL = 'Task status'
				,	tsk.ACTIVITY_DT 										LABEL = 'Task activity date'
				,	tsk.CREATED_DT_TM 			AS TASK_CREATED_DT_TM 		LABEL = 'Task created date time'
				,	tsk.RECORD_TYPE_ID 			AS TASK_RECORD_TYPE_ID 		LABEL = 'Task record type id'
				,	tsk.OUTCOME_STAGE_TX 		AS TASK_OUTCOME_STAGE_TX 	LABEL = 'Task outcome stage'
				,	tsk.TYPE_TX 				AS TASK_TYPE_TX 			LABEL = 'Task type'
				,	tsk.TASKSUBTYPE_TX 										LABEL = 'Task subtype'
			from		DWH.DW_CRM_OMNI_ASSESSMENT_TASK_&view.	om
			LEFT JOIN	DWH.DW_CRM_TASK_&view.					tsk
			ON			om.TASK_RELATION_ID = tsk.WHAT_ID
			ORDER BY 	om.OUTCOME_ID, om.OMNI_ASSESSMENT_TASK_ID;
	quit;
	%datepart(DC_TASK_DATA);

	/*=====================================================================================*/
	/* CHILD: Interactions linked to an outcome (with interaction summary)                 */
	/* Interaction link Linked_record_id_tx = Outcome id (ASSUMED - confirm)               */
	/*=====================================================================================*/
	proc sql;
		create table DC_INTERACTION_DATA as
			select	il.LINKED_RECORD_ID_TX 			AS OUTCOME_ID 			LABEL = 'Outcome id (linked record id)'
				,	il.INTERACTION_LINK_ID 									LABEL = 'Interaction link id'
				,	il.CREATED_BY_ID 				AS LINK_CREATED_BY_ID 	LABEL = 'Interaction link created by id'
				,	il.IS_DELETED_FL 				AS LINK_IS_DELETED_FL 	LABEL = 'Interaction link deleted flag'
				,	il.NOTIFIED_DT 					AS LINK_NOTIFIED_DT 	LABEL = 'Interaction link notified date'
				,	il.LAST_MODIFIED_BY_ID 			AS LINK_LAST_MODIFIED_BY_ID	LABEL = 'Interaction link last modified by id'
				,	i.INTERACTION_ID 										LABEL = 'Interaction id'
				,	i.CLAIM_ID 						AS SF_CLAIM_ID 			LABEL = 'Salesforce Claim Id'
				,	i.RECORD_ID 											LABEL = 'Interaction record id'
				,	i.OWNER_ID 						AS INTERACTION_OWNER_ID LABEL = 'Interaction owner id'
				,	i.LAST_MODIFIED_BY_ID 			AS INTERACTION_LAST_MODIFIED_BY_ID LABEL = 'Interaction last modified by id'
				,	i.CREATED_DT_TM 				AS INTERACTION_CREATED_DT_TM LABEL = 'Interaction created date time'
				,	i.NOTIFIED_DT 					AS INTERACTION_NOTIFIED_DT	LABEL = 'Interaction notified date'
				,	i.DIDTHEMEETINGHAPPEN_TX 								LABEL = 'Did the meeting happen'
				,	i.INTERACTION_TY 										LABEL = 'Interaction type'
				,	i.RESCHEDULETHISMEETING_TX 								LABEL = 'Reschedule this meeting'
				,	i.STATUS_TX 					AS INTERACTION_STATUS_TX LABEL = 'Interaction status'
				,	i.STAGE_TX 						AS INTERACTION_STAGE_TX LABEL = 'Interaction stage'
				,	i.REASON_CD 											LABEL = 'Interaction reason code'
				,	i.AGREE_ACTION_TX 										LABEL = 'Agreed action'
				,	i.COUNTOF_ATTENDEES_NB 									LABEL = 'Count of attendees'
				,	i.COUNTOF_PROVIDER_ATTENDEES_NB 						LABEL = 'Count of provider attendees'
				,	i.COUNTOF_EMPLOYER_ATTENDEES_NB 						LABEL = 'Count of employer attendees'
				,	i.LINKED_OBJECTIVES_CT 									LABEL = 'Linked objectives count'
				,	s.INTERACTION_SUMMARY_ID 								LABEL = 'Interaction summary id'
				,	s.INTERACTION_SUMMARY_NAME 								LABEL = 'Interaction summary name'
				,	s.STATUS_TX 					AS SUMMARY_STATUS_TX 	LABEL = 'Interaction summary status'
			from		DWH.DW_CRM_INTERACTION_LINK_&view.		il
			INNER JOIN	DWH.DW_CRM_INTERACTION_&view.			i
			ON			il.INTERACTION_ID = i.INTERACTION_ID
			LEFT JOIN	DWH.DW_CRM_INTERACTION_SUMMARY_&view.	s
			ON			i.INTERACTION_ID = s.INTERACTION_ID
			WHERE		il.IS_DELETED_FL = 'N' /*remove deleted links*/
			ORDER BY 	il.LINKED_RECORD_ID_TX, i.INTERACTION_ID;
	quit;
	%datepart(DC_INTERACTION_DATA);

	/*=====================================================================================*/
	/* CHILD: Interaction attendees                                                        */
	/*=====================================================================================*/
	proc sql;
		create table DC_ATTENDEE_DATA as
			select	a.INTERACTION_ATTENDEE_ID 								LABEL = 'Interaction attendee id'
				,	a.INTERACTION_ID 										LABEL = 'Interaction id'
				,	a.SERVICE_TY 											LABEL = 'Service type'
				,	a.ATTENDEE_TY 											LABEL = 'Attendee type'
				,	a.ATTENDEE_NAME 										LABEL = 'Attendee name'
				,	a.ATTENDANCE_METHOD_TX 									LABEL = 'Attendance method'
			from		DWH.DW_CRM_INTERACTION_ATTENDEE_&view.	a
			ORDER BY 	a.INTERACTION_ID, a.INTERACTION_ATTENDEE_ID;
	quit;
	%datepart(DC_ATTENDEE_DATA);

	/*=====================================================================================*/
	/* CHILD: Documents linked to a record (with document reference)                       */
	/* Content doc ref link Linked_record_id_tx = Outcome id (ASSUMED - confirm)           */
	/*=====================================================================================*/
	proc sql;
		create table DC_DOCUMENT_DATA as
			select	l.CONTENT_DOC_REF_LINK_ID 								LABEL = 'Content document reference link id'
				,	l.LINKED_RECORD_ID_TX 			AS OUTCOME_ID 			LABEL = 'Outcome id (linked record id)'
				,	l.CONTENT_DOCUMENT_REFERENCE_ID 						LABEL = 'Content document reference id'
				,	d.CONTENT_DCMNT_RFRNCE_NAME 							LABEL = 'Content document reference name'
				,	d.DOCUMENT_TY 											LABEL = 'Document type'
				,	d.CREATED_DT_TM 				AS DOCUMENT_CREATED_DT_TM LABEL = 'Document created date time'
			from		DWH.DW_CRM_CONTENT_DOC_REF_LINK_&view.	l
			LEFT JOIN	DWH.DW_CRM_CONTENT_DCMNT_RFRNCE_&view.	d
			ON			l.CONTENT_DOCUMENT_REFERENCE_ID = d.CONTENT_DCMNT_RFRNCE_ID
			ORDER BY 	l.LINKED_RECORD_ID_TX, l.CONTENT_DOC_REF_LINK_ID;
	quit;
	%datepart(DC_DOCUMENT_DATA);

	/*=====================================================================================*/
	/* CHILD: Salesforce cases (with Salesforce claim)                                     */
	/*=====================================================================================*/
	proc sql;
		create table DC_CASE_DATA as
			select	cs.CASE_ID 												LABEL = 'Case id'
				,	cs.CLAIM_NBR_TX 										LABEL = 'Claim number'
				,	cs.PSS_CLAIM_ID 			AS SF_CLAIM_ID 				LABEL = 'Salesforce Claim Id'
				,	crm_clm.ACCTION_CLM_NB 									LABEL = 'ACCtion claim number'
				,	cs.RECORD_TYPE_ID 			AS CASE_RECORD_TYPE_ID 		LABEL = 'Case record type id'
				,	cs.TYPE_TX 					AS CASE_TYPE_TX 			LABEL = 'Case type'
				,	cs.TYPE_OF_REQUEST_TX 									LABEL = 'Type of request'
				,	cs.CASE_DT 												LABEL = 'Case date'
				,	cs.CREATED_DT_TM 			AS CASE_CREATED_DT_TM 		LABEL = 'Case created date time'
				,	cs.DATE_OF_APPLICATION_DT 								LABEL = 'Date of application'
				,	cs.SUBJECT_TX 				AS CASE_SUBJECT_TX 			LABEL = 'Case subject'
				,	cs.OWNER_ID 				AS CASE_OWNER_ID 			LABEL = 'Case owner id'
				,	cs.STATUS_TX 				AS CASE_STATUS_TX 			LABEL = 'Case status'
			from		DWH.DW_CRM_CASE_&view.					cs
			LEFT JOIN	DWH.DW_CRM_CLAIM_&view.					crm_clm
			ON			cs.PSS_CLAIM_ID = crm_clm.CLAIM_ID
			ORDER BY 	cs.PSS_CLAIM_ID, cs.CASE_ID;
	quit;
	%datepart(DC_CASE_DATA);

	/*=====================================================================================*/
	/* CHILD: Service invoice lines (legacy ACCtion), keyed on legacy Claim_id             */
	/*=====================================================================================*/
	proc sql;
		create table DC_INVOICE_DATA as
			select	inv.CLAIM_ID 											LABEL = 'Claim id'
				,	inv.SERVICE_DT 											LABEL = 'Service date'
				,	inv.PAYMENT_TYPE_CD 									LABEL = 'Payment type code'
				,	inv.CLAIM_PAYMENT_STATUS_CD 							LABEL = 'Claim payment status code'
			from		DWH.DW_SERVICE_INVOICE_LINE_&view.		inv
			ORDER BY 	inv.CLAIM_ID, inv.SERVICE_DT;
	quit;
	%datepart(DC_INVOICE_DATA);

%mend create_dataset;

/************************************************************************************************************************************/
/* Macro to write Master datasets																									*/
/************************************************************************************************************************************/
%macro write_datasets(lib, snap);
	%logmsg(&lib.);

	data &lib..dc_outcome_data_&snap;
		set DC_OUTCOME_DATA;
	run;

	data &lib..dc_task_data_&snap;
		set DC_TASK_DATA;
	run;

	data &lib..dc_interaction_data_&snap;
		set DC_INTERACTION_DATA;
	run;

	data &lib..dc_attendee_data_&snap;
		set DC_ATTENDEE_DATA;
	run;

	data &lib..dc_document_data_&snap;
		set DC_DOCUMENT_DATA;
	run;

	data &lib..dc_case_data_&snap;
		set DC_CASE_DATA;
	run;

	data &lib..dc_invoice_data_&snap;
		set DC_INVOICE_DATA;
	run;

%mend write_datasets;

/********************************************************************************/
/* Below logic is to determine which datasets to create: Daily, Weekly, Monthly	*/
/********************************************************************************/

/* Daily - runs every day without exception*/

/* Create the dataset using the daily view */
%create_dataset(dv);

/* Save to the master datasets folder for production use */
%write_datasets(lib=dnc, snap=dv);

/* Save a copy in the archive folder with the snapshot date appended */
%write_datasets(lib=dv_arch, snap=&SNAPSHDT.);


/* Weekly */
/* Runs on a sunday (wkday macro is set to 1 for Sunday) */
%if (&wkday.= 1) %then
	%do;
		/* Create the dataset using the weekly view */
		%create_dataset(wv);

		/* Save to the master datasets folder for production use */
		%write_datasets(lib=dnc, snap=wv );

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
		%write_datasets(lib=dnc, snap=mv);

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
	%write_datasets(lib=dnc, snap=wv );
	%write_datasets(lib=wv_arch, snap=&weeklydt.);

	/* run monthly */
	%create_dataset(mv);
	%write_datasets(lib=dnc, snap=mv);
	%write_datasets(lib=mv_arch, snap=&yyyymm.);
%mend force_update;

%if (&manual_update eq yes) %then
	%do;
		%logmsg('Forcing the weekly and monthly datasets to run on &day_name');
		%force_update;
	%end;
