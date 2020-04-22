/***********************************************************************
* Class Name: InboundEmailAEX                                          * 
* Author: Zoran Subotic                                                *
* Date Apr-2019                                                        *    
* Requirement/Project Name: KLM - CS Flow                              *       
* Requirement/Project Description:                                     *    
*                                                                      * 
* email inbound service fo receiving the e-mail messages from AEX      *
* parse the message and store the relevat data in SF, make the         *
* parent case and serviceable and unserviceable child cases            *
* if case is succesfully created it generates the return tag for the   *
* unserviceble Case attaches is under it and sends it back to the AEX  *
* if the case is allready created for the IFAX number skip all         *
* This class also will call the web service that is generating the QR  *
* code. It is wired with the Visualforce page that is generating pdf.  *
* Please note that the credentials for the service are in cus.metadata *
* and that the Remote Site Settings needs to contain the service domain*
* There are two methods, one that returns base64 image encoded can be  * 
* used in VF pages directly, and the other one is saving image as att. *
* is used when generating pdf since the pdf engine can only show actual*
* images from the location and can't convert b64 to image on the fly   *
* like browser engine can ...										   *
* Since the qr code generator service is critical for the business     *
* processes, we added a backup service on google that will be used     *
* if for some reason the original service would fail                   *
*                                                                      *
* Revision:                                                            *
* - SFEMCS-579) Parse pooltype
 ***********************************************************************/
global class InboundEmailAEX implements Messaging.InboundEmailHandler{

    /**
    * method used to access InboundEmail object to retrieve the contents, headers, and attachments of inbound email messages
    * to parse body and get necessary data to create the case
    * @param email 
    * @param envelope 
    * @return Messaging.InboundEmailResult 
    **/
    global Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailresult();
        String action,accName,ordNumber,ifaxNUmber, partNumber, caseId, poolType;
        List<String> subList = new List<String>();
        List<String> bdyList = new List<String>();
        List<String> poolList = new List<String>();
        String orgEmailAddress = Utils.isSandbox() == true ? CONSTANTS.EM_SANDBOX : CONSTANTS.EM_PROD;

        Boolean isAEX_Email = email.fromAddress.endsWith('aeroxchange.com') || 
                              (email.fromAddress.endsWith('klm.com') && email.subject.startsWith('EO Creation'));
        Boolean isCSP_Email = email.fromAddress.endsWith('boeing.com') || 
                              (email.fromAddress.endsWith('klm.com') && email.subject.endsWith('Acknowledgement'));

        //parse the subject in the list
        if (isAEX_Email) {
            subList = email.subject.split('\\|');
            action = subList[0];
            accName = subList[1].trim();
            ordNumber = subList[4];
            partNumber = subList[5];
        }        
        else if (isCSP_Email) {
            subList = email.subject.split('/');

            // Example: TUI AIRWAYS/ZDA/BRI/2203734/PR2420219/572756-1/Planned/LTN/Acknowledgement

            action = subList[8];
            accName = subList[0].trim();
            ordNumber = subList[4];
            partNumber = subList[5];

            ifaxNumber = subList[3];
        }        

        if(action.contains('Cancelation')) { //find all related cases and set status and queue to canceled
            //cancelRequest(ordNumber,partNumber); business needs to ginve directions on this one
        }else{
            //take the ifax from the body
            if (isAEX_Email) {
                if(email.htmlBody != null){
                    bdyList = email.htmlBody.split('%%');
                }else{
                    bdyList = email.plainTextBody.split('%%');
                }
                ifaxNumber = bdyList[1].split('%')[0];
                //check for poolType
                poolList = bdyList[1].split('Pool Type ');
                if(poolList.size() > 0){
                    //system.debug('poolList >>'+poolList);
                    //EO Context will always come after Pool type
                    if(poolList[1].split('EO Context').size() > 0){
                        poolType = poolList[1].split('EO Context')[0];
                    }
                }
                //system.debug(' pool type >>'+poolType);
            }
            else if (isCSP_Email) { // Retrieved in previous isCSP_Email block
            }

            if([SELECT Id FROM Case WHERE IFAX_Number__c = :ifaxNumber].size() == 0){ //create request if one is allready not created previously
                caseId = createRequest(pooltype, accName, ordNumber, partNumber, ifaxNumber, isCSP_Email ? 'CSP' : (isAEX_Email ? 'AEX' : ''));
                String eml = E_M_CS_Settings__c.getInstance().AEX_To_Address__c;
                InboundEmailAEX.saveFileAndSendReturnTag(ifaxNumber, ordNumber, caseId, eml, orgEmailAddress, isAEX_Email);
            }
        }

        return result;
    }
    
    
    /**
    * this method will cancel the existing requests
    * @param ordNumber 
    * @param partNumber 
    * @return void 
    **/
    /* Temporarely commented out, as it is not used (yet) and we don't have a test method for it
    
    private void cancelRequest(String ordNumber, String partNumber){
        List<Case> cases = [SELECT Id,Status,OwnerId FROM Case WHERE Parent_Exchange_Order_Number__c = :ordNumber AND Parent_Shipped_Part_Number__c = :partNumber];
        Id canceledQueue = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :CONSTANTS.QU_CANCEL].Id;
        //system.debug(' cases >>'+cases[0]);
        //system.debug(' canceledQueue >>>'+canceledQueue);
        if(cases.size() > 0){
            for(Case cs:cases){
                cs.Status = CONSTANTS.CS_STATUS_CN;
                cs.OwnerId = canceledQueue;
            }
            update cases;
        }
    }

    */

    /**
    * this method is creating the Master, Servicable and unservicable case
    * @param accName 
    * @param ordNumber 
    * @param partNUmber 
    * @param ifaxNUmber 
    * @param source 
    * @return ID 
    **/
    private ID createRequest(String pooltype, String accName, String ordNumber, String partNUmber, String ifaxNUmber, String source){
        Id rtServCaseId, rtUnservCaseId, rtParentCaseId, queueId;
        rtUnservCaseId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(CONSTANTS.RT_CASE_CS_UNSERVICEABLE).getRecordTypeId();
        rtServCaseId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(CONSTANTS.RT_CASE_CS_SERVICEABLE).getRecordTypeId();
        rtParentCaseId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(CONSTANTS.RT_CASE_CS).getRecordTypeId();
        queueId = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = :CONSTANTS.QU_NEW_REQ].Id;
        //check for the account first
        Account acc = arrangeAccount(accName);

        String airCraftType;
        Boolean isKLMResponsible = false;
        //pooltype is populated for AEX, Boeing CSP is alws 737. Code need to be changed if required
        if(pooltype!=null){
            //System.debug('pooltype >>'+pooltype);
            if(pooltype.indexOf('NONE') == -1) {
                airCraftType = '737';
                if(pooltype.indexOf('Expand') > -1) { isKLMResponsible = true; }
            } 
        }
    
        String accId = acc.Id;
        Case csCasePar,csCaseUns,csCaseSer;

        //create the parent case first
        csCasePar = new Case();
        csCasePar.RecordTypeId = rtParentCaseId;
        csCasePar.AccountId = accId;
        csCasePar.Exchange_Order_Number__c = ordNumber;
        csCasePar.IFAX_Number__c = ifaxNumber;
        csCasePar.Shipped_Part_Number__c = partNUmber;
        csCasePar.Status = 'New Request';
        csCasePar.Subject = source + ' - ' + ordNumber;
        csCasePar.Customer_Name__c = accName;
        csCasePar.OwnerId = queueId;
        csCasePar.Origin = source + ' Email';
        try{
            insert csCasePar;
        }catch(Exception e){
            System.debug('Exception happened during the case insert of the parent Case: '+e.getMessage()+', this is the cause: '+e.getCause());
            return null;
        }
        
        //prepare the unserviceable child case record
        csCaseUns = new Case();
        csCaseUns.RecordTypeId = rtUnservCaseId;
        csCaseUns.Status = 'New Request';
        csCaseUns.Subject = source + ' - Unserviceable Request';
        csCaseUns.ParentId = csCasePar.Id;
        csCaseUns.OwnerId = queueId;
        csCaseUns.Customer_Name__c = accName;
        csCaseUns.Origin = source + ' Email';
        if (source == 'CSP') { csCaseUns.CS_Aircraft_Type__c = '737'; }
        if (airCraftType!=null) {  csCaseUns.CS_Aircraft_Type__c = airCraftType; }
        if (isKLMResponsible) {  csCaseUns.Repair_Responsible__c = 'KLM'; }
        csCaseUns.Pool_Type__c = poolType;
        try{
            insert csCaseUns;
        }catch(Exception e){
            System.debug('Exception happened during the case insert of the unserviceable Case: '+e.getMessage()+', this is the cause: '+e.getCause());
            return null;
        }
         //prepare the serviceable child case record
        csCaseSer = new Case();
        csCaseSer.RecordTypeId = rtServCaseId;
        csCaseSer.Status = 'New Request';
        csCaseSer.Subject = source + ' - Serviceable Request';
        csCaseSer.ParentId = csCasePar.Id;
        csCaseSer.OwnerId = queueId;
        csCaseSer.Customer_Name__c = accName;
        csCaseSer.Origin = source + ' Email';
        try{
            insert csCaseSer;
        }catch(Exception e){
            System.debug('Exception happened during the case insert of the Serviceable Case: '+e.getMessage()+', this is the cause: '+e.getCause());
        }
         // Create the Part_Request_Data__c child of the unserviceable child case record
        Part_Request_Data__c prdObj = new Part_Request_Data__c();
        prdObj.Case__c = csCaseUns.Id;
        prdObj.Error_Message__c = 'SFDC initiated instance';
        // prdObj.Part_Number__c = partNUmber;
        try{
            insert prdObj;
        }catch(Exception e){
            System.debug('Exception happened during the insert of the Part_Request_Data__c: '+e.getMessage()+', this is the cause: '+e.getCause());
        }
        //return the case id for the unserviceable since that one is used in the QR-code data creation
        return csCaseUns.Id;
    }
    
    /**
    * This method is checking if there is E&M CS account in the system otherwise creates the new account record
    * It returns the account 
    * @param accName 
    * @return Account 
    **/
    private Account arrangeAccount(String accName) {

        Id rtAccountEM_CSId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(CONSTANTS.RT_ACCOUNT_CS).getRecordTypeId();
        Account acc;
        List<Account> accLst = [SELECT Id, Name FROM Account
				                where Name = :accName AND recordTypeId = :rtAccountEM_CSId];
        if (accLst.size() > 0) {
            // Remember, there should only be one account
            return accLst[0];
        }
        // If not found, create a new account
        acc = new Account(Name = accName, RecordTypeId = rtAccountEM_CSId);
        insert acc;
        return acc;
    }

    /**
    * this method is calling the qr-code tag generator and inserts it as an attachment 
    * Its is also used to call the Queue to genrate the attachment as pdf and attach to case and send as email
    * @param ifaxNUmber 
    * @param ordNumber 
    * @param caseId 
    * @param eml 
    * @param orgEmailAddress 
    * @param sendTheReturnTag
    * @return void 
    **/
    @future(callout=true)
    public static void saveFileAndSendReturnTag(String ifaxNUmber, String ordNumber, String caseId, String eml, String orgEmailAddress,
                                                Boolean sendTheReturnTag) {
        try{
            if(caseId != null){
                // this approach is used to avoid the XSRF and not use any DML in action function of the returnPage
                String delName = 'tmpComponentReturnTag'+caseId+'.png';
                delete [SELECT ID FROM Attachment WHERE Name = :delName];
                String b64 = getB64Image(caseId);
                Attachment att = new Attachment();
                att.Body = EncodingUtil.base64Decode(b64);
                att.ContentType = 'image/png';
                att.Name = 'tmpComponentReturnTag'+caseId+'.png';
                att.ParentId = caseId; 
                insert att;
                //Queue to genrate the PDF and    
                EM_GenerateReturnTagQueueable queueTransaction = new EM_GenerateReturnTagQueueable(caseId, eml,ifaxNUmber,ordNumber,orgEmailAddress,sendTheReturnTag);
                System.enqueueJob(queueTransaction);
                   
            }
        }catch(Exception e){
            System.debug('Exception happened during the file insert: '+e.getMessage()+', this is the cause: '+e.getCause());
        }
    }

    /**
    * This page is used to generate QR code from the heroku app.ApexPages
    * if heroku is down then we added a backup service on google that will be used
    * @return String 
    **/
    private static String getB64Image(String caseId){
        String data = System.Url.getSalesforceBaseUrl().toExternalForm()+'/';
        String color,bckgcol,size,padding,params;
        QRCodeGenerator__mdt qrd = [SELECT DeveloperName,Endpoint__c,Password__c,QRCodeBackgroundColor__c,QRCodeColor__c,QRPadding__c,QRSize__c,Username__c FROM QRCodeGenerator__mdt WHERE DeveloperName = 'ReturnTag' LIMIT 1];
        color = qrd.QRCodeColor__c;
        bckgcol = qrd.QRCodeBackgroundColor__c;
        size = qrd.QRSize__c;
        padding = qrd.QRPadding__c;
        
        params = (color!=null)?'&color='+EncodingUtil.urlEncode(color,'UTF-8'):'';
        params+= (bckgcol!=null)?'&bckgcol='+EncodingUtil.urlEncode(bckgcol,'UTF-8'):'';
        params+= (size!=null)?'&size='+size:'';
        params+= (padding!=null)?'&padding='+padding:'';
        //uncomment in the next releases when ready to go live with the qr code containing the link to the case record
        String finalUrl = qrd.Endpoint__c+data+caseId+params;
        String googleUrl = 'https://chart.googleapis.com/chart?cht=qr&chl='+data+caseId+'&chs=250x250&chld=KLM';
		
        //String finalUrl = qrd.Endpoint__c+cs.Parent_IFAX_Number__c+params;
        //String googleUrl = 'https://chart.googleapis.com/chart?cht=qr&chl='+cs.Parent_IFAX_Number__c+'&chs=250x250&chld=KLM';
        
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        HttpResponse res = new HttpResponse();
        
        req.setMethod('GET');
        req.setTimeout(30000); 
        req.setEndpoint(finalUrl);
        req.setHeader('Authorization', 'Basic '+EncodingUtil.base64Encode(Blob.valueOf(qrd.Username__c+':'+qrd.Password__c)));
        res = http.send(req);
        //check if the response is as expected
        if(res.getStatusCode() != 200){ //something went wrong try the google generator
            http = new Http();
            req = new HttpRequest();
            res = new HttpResponse();
            req.setMethod('GET');
            req.setTimeout(30000); 
            req.setEndpoint(googleUrl);
            res = http.send(req);
        	return EncodingUtil.base64Encode(res.getBodyAsBlob());
        }
        //return result from the klm qrcode generator app
		return res.getBody();
    }
    
}
