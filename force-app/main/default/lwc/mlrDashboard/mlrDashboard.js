import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getDashboardStats from '@salesforce/apex/MLRDashboardController.getDashboardStats';
import getRecentSubmissions from '@salesforce/apex/MLRDashboardController.getRecentSubmissions';

const COLUMNS = [
    {
        label: 'Submission #', fieldName: 'recordUrl', type: 'url',
        typeAttributes: { label: { fieldName: 'Name' }, target: '_self' },
        initialWidth: 140
    },
    { label: 'Asset Type', fieldName: 'Asset_Type__c', type: 'text', initialWidth: 130 },
    { label: 'Program', fieldName: 'Program__c', type: 'text' },
    { label: 'Status', fieldName: 'Status__c', type: 'text', initialWidth: 120 },
    { label: 'Confidence', fieldName: 'Overall_Confidence__c', type: 'text', initialWidth: 110 },
    { label: 'Agent Run', fieldName: 'Agent_Run_Status__c', type: 'text', initialWidth: 110 },
    { label: 'Submitted', fieldName: 'Submitted_Date__c', type: 'date', initialWidth: 120 }
];

export default class MlrDashboard extends LightningElement {
    @track stats = {};
    @track submissions = [];
    @track isLoading = false;
    @track showSubmissionModal = false;

    columns = COLUMNS;
    _wiredStatsResult;
    _wiredSubmissionsResult;

    @wire(getDashboardStats)
    wiredStats(result) {
        this._wiredStatsResult = result;
        if (result.data) {
            this.stats = result.data;
        }
    }

    @wire(getRecentSubmissions)
    wiredSubmissions(result) {
        this._wiredSubmissionsResult = result;
        if (result.data) {
            this.submissions = result.data.map(s => ({
                ...s,
                recordUrl: '/lightning/r/MLR_Submission__c/' + s.Id + '/view'
            }));
        }
    }

    handleNewSubmission() {
        this.showSubmissionModal = true;
    }

    handleCloseModal() {
        this.showSubmissionModal = false;
    }

    handleFlowStatusChange(event) {
        const status = event.detail.status;
        if (status === 'FINISHED' || status === 'FINISHED_SCREEN') {
            this.showSubmissionModal = false;
            this.toast('Submission Created', 'AI agents are now reviewing your document.', 'success');
            this.handleRefresh();
        }
        if (status === 'ERROR') {
            this.showSubmissionModal = false;
            this.toast('Error', 'Something went wrong. Please try again.', 'error');
        }
    }

    handleRefresh() {
        this.isLoading = true;
        Promise.all([
            refreshApex(this._wiredStatsResult),
            refreshApex(this._wiredSubmissionsResult)
        ]).finally(() => {
            this.isLoading = false;
        });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
