import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getAgentResultsForSubmission from '@salesforce/apex/MLRDashboardController.getAgentResultsForSubmission';

const ICONS = {
    Medical: 'utility:heart',
    Legal: 'utility:currency',
    Regulatory: 'utility:checkin'
};

const HEADER_CLASSES = {
    Medical:     'agent-header agent-header--medical',
    Legal:       'agent-header agent-header--legal',
    Regulatory:  'agent-header agent-header--regulatory'
};

const CONFIDENCE_CLASSES = {
    High:   'confidence-pill confidence-pill--high',
    Medium: 'confidence-pill confidence-pill--medium',
    Low:    'confidence-pill confidence-pill--low'
};

const STATUS_CLASSES = {
    Complete:  'status-badge status-badge--complete',
    Running:   'status-badge status-badge--running',
    Pending:   'status-badge status-badge--pending',
    Failed:    'status-badge status-badge--failed'
};

export default class MlrAgentResults extends LightningElement {
    @api recordId;
    @track isLoading = true;

    _wiredResult;
    _rawResults = [];

    @wire(getAgentResultsForSubmission, { submissionId: '$recordId' })
    wiredResults(result) {
        this._wiredResult = result;
        this.isLoading = false;
        if (result.data) {
            this._rawResults = result.data;
        } else {
            this._rawResults = [];
        }
    }

    get agentResults() {
        return this._rawResults.map(r => {
            const grounding = r.Grounding_Score__c;
            const pct = grounding != null ? Math.round(grounding * 100) : 0;
            return {
                ...r,
                iconName: ICONS[r.Agent_Type__c] || 'utility:einstein',
                cardClass: 'agent-card',
                headerClass: HEADER_CLASSES[r.Agent_Type__c] || 'agent-header',
                confidencePillClass: CONFIDENCE_CLASSES[r.Confidence__c] || 'confidence-pill',
                statusClass: STATUS_CLASSES[r.Processing_Status__c] || 'status-badge',
                groundingPct: pct,
                showGrounding: grounding != null,
                groundingBarStyle: `width:${pct}%;background:${pct >= 80 ? '#22c55e' : pct >= 60 ? '#f59e0b' : '#ef4444'}`
            };
        });
    }

    get hasResults() {
        return this._rawResults && this._rawResults.length > 0;
    }

    @api
    refresh() {
        this.isLoading = true;
        return refreshApex(this._wiredResult).then(() => {
            this.isLoading = false;
        });
    }
}
