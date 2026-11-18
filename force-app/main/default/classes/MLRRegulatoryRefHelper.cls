public without sharing class MLRRegulatoryRefHelper {
    public static List<MLR_Regulatory_Reference__c> getActiveRefs(String stage) {
        return [
            SELECT Name, Stage__c, Content__c, Is_Active__c
            FROM MLR_Regulatory_Reference__c
            WHERE Stage__c = :stage AND Is_Active__c = true
            ORDER BY Name
        ];
    }

    // Returns a map of stage → concatenated regulatory grounding text for all active references.
    // Called from MLROrchestrationService to avoid direct SOQL on Content__c in that class.
    public static Map<String, String> getGroundingByStage() {
        Map<String, String> result = new Map<String, String>();
        for (MLR_Regulatory_Reference__c ref : [
            SELECT Stage__c, Name, Content__c
            FROM MLR_Regulatory_Reference__c
            WHERE Is_Active__c = true
            ORDER BY Stage__c, Name
        ]) {
            String existing = result.containsKey(ref.Stage__c) ? result.get(ref.Stage__c) + '\n\n' : '';
            result.put(ref.Stage__c, existing + '--- ' + ref.Name + ' ---\n' + ref.Content__c);
        }
        return result;
    }

    @InvocableMethod(label='Seed Regulatory References')
    public static void seedRegulatoryRefs(List<String> dummy) {
        List<MLR_Regulatory_Reference__c> existing = [SELECT Id FROM MLR_Regulatory_Reference__c];
        if (!existing.isEmpty()) delete existing;

        List<MLR_Regulatory_Reference__c> refs = new List<MLR_Regulatory_Reference__c>{
            new MLR_Regulatory_Reference__c(
                Name = 'FDA Prescribing Information — Fair Balance Requirement',
                Stage__c = 'Medical', Is_Active__c = true,
                Content__c = 'Per FDA guidance, promotional materials must present risk information with a prominence and readability reasonably comparable to the presentation of benefits (fair balance). Safety information must not be minimized, obscured, or included only in footnotes. Efficacy claims must be accompanied by balanced risk disclosure. All absolute efficacy claims require definitive evidentiary support from primary RCT endpoints.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'ICMJE Clinical Trial Reporting Standards',
                Stage__c = 'Medical', Is_Active__c = true,
                Content__c = 'ICMJE standards require that clinical claims reference primary pre-specified endpoints from registered trials. Exploratory, post-hoc, or subgroup analyses must be labeled as such and cannot be presented as definitive efficacy evidence. Comparative claims must be based on head-to-head RCT data with appropriate statistical context (p-values, confidence intervals, NNT).'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'PhRMA Code — Scientific Data Integrity',
                Stage__c = 'Medical', Is_Active__c = true,
                Content__c = 'The PhRMA Code requires that scientific claims be accurate, balanced, and based on substantial evidence. Materials must not cherry-pick favorable study results while omitting unfavorable ones. Statistical significance must not be conflated with clinical meaningfulness. Surrogate endpoint data must be clearly distinguished from patient outcome data.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'FTC Act Section 5 — Deceptive Trade Practices',
                Stage__c = 'Legal', Is_Active__c = true,
                Content__c = 'Under FTC Act Section 5, advertising claims must be truthful, non-deceptive, and substantiated before they are made. Superlative claims (best, only, most trusted, number one) are inherently deceptive unless supported by competent and reliable scientific or market evidence. Disclaimers that contradict the headline claim do not cure deceptiveness.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'Lanham Act Section 43a — Comparative Advertising',
                Stage__c = 'Legal', Is_Active__c = true,
                Content__c = 'Lanham Act Section 43(a) prohibits false or misleading statements of fact in commercial advertising. Comparative claims must be literally true and not misleading in context. Market share and performance comparisons require current, statistically valid substantiation. Implied comparisons are as actionable as express ones.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'Anti-Kickback Statute — Pricing and Reimbursement',
                Stage__c = 'Legal', Is_Active__c = true,
                Content__c = 'The federal Anti-Kickback Statute (42 U.S.C. 1320a-7b(b)) prohibits offering or receiving anything of value to induce referrals covered by federal healthcare programs. Promotional materials referencing patient assistance programs, copay cards, or reimbursement support must not imply improper inducement.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'FDA 21 CFR 202.1(e)(5) — Fair Balance in Advertising',
                Stage__c = 'Regulatory', Is_Active__c = true,
                Content__c = 'FDA 21 CFR Section 202.1(e)(5) requires prescription drug advertisements to present a fair balance of information relating to side effects and contraindications. Risk information must be presented with prominence and readability reasonably comparable to the presentation of benefits. Accelerated speech, small print, or obscured risk disclosures do not satisfy fair balance.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'FDA 21 CFR 202.1(e)(1) — Brief Summary Requirement',
                Stage__c = 'Regulatory', Is_Active__c = true,
                Content__c = 'FDA 21 CFR Section 202.1(e)(1) requires that print prescription drug advertisements include a brief summary of each side effect and contraindication. The brief summary must not be in a font size smaller than the main promotional text. For digital materials, the PI or a direct link must be readily accessible.'
            ),
            new MLR_Regulatory_Reference__c(
                Name = 'FDA OPDP — Off-Label Promotion Prohibition',
                Stage__c = 'Regulatory', Is_Active__c = true,
                Content__c = 'The FDA Office of Prescription Drug Promotion (OPDP) enforces prohibition on off-label promotion under the FDCA. Promotional materials may only promote uses consistent with the FDA-approved labeling. Claims about unapproved uses, patient populations, routes, or dosages constitute off-label promotion regardless of whether clinical data supports the use.'
            )
        };
        insert refs;
        System.debug('Seeded ' + refs.size() + ' regulatory references');
    }
}
