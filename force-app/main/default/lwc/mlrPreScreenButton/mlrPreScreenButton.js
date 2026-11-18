import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import runPreScreen from '@salesforce/apex/MLRPreScreenController.runPreScreen';
import getResults from '@salesforce/apex/MLRPreScreenController.getResults';

const POLL_INTERVAL_MS  = 20000;
const POLL_MAX_ATTEMPTS = 15; // 5 minutes total

export default class MlrPreScreenButton extends LightningElement {
    @api recordId;
    @track results = [];
    @track isRunning = false;
    @track statusMessage = '';
    @track loaded = false;
    @track fileReady = false;   // file uploaded, waiting for user to click run
    @track uploadedFileName = '';

    _pollTimer = null;
    _pollCount = 0;

    connectedCallback() {
        this.loadResults();
    }

    disconnectedCallback() {
        this._clearPoll();
    }

    get hasResults() {
        return this.loaded && this.results.length > 0;
    }

    get noResults() {
        return this.loaded && this.results.length === 0 && !this.isRunning && !this.fileReady;
    }

    get runningMessage() {
        return 'Medical → Legal → Regulatory running… TXT: ~30 sec • PDF/DOCX: 2–4 min';
    }

    async loadResults() {
        try {
            const data = await getResults({ submissionId: this.recordId });
            this.results = data;
            this.loaded = true;
        } catch (error) {
            this.loaded = true;
        }
    }

    // First upload (no results yet) → auto-scan immediately.
    // Re-upload (results already exist) → show banner, wait for manual Run click.
    async handleUploadFinished(event) {
        const files = event.detail.files;
        if (!files || files.length === 0) return;
        this.uploadedFileName = files[0].name;
        this.statusMessage = '';

        if (this.results.length === 0) {
            // Initial submission — start scan automatically
            this.fileReady = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'File Uploaded',
                message: this.uploadedFileName + ' uploaded. Starting pre-screen automatically…',
                variant: 'success'
            }));
            await this.startPreScreen();
        } else {
            // Re-upload — prompt user to click Run Pre-Screener manually
            this.fileReady = true;
            this.dispatchEvent(new ShowToastEvent({
                title: 'File Ready',
                message: '✔ ' + this.uploadedFileName + ' uploaded. Click Run Pre-Screener to start the scan.',
                variant: 'success'
            }));
        }
    }

    async handleRunPreScreen() {
        this.fileReady = false;
        this.uploadedFileName = '';
        await this.startPreScreen();
    }

    async startPreScreen() {
        this._clearPoll();
        this.isRunning = true;
        this.statusMessage = '';
        this._pollCount = 0;

        try {
            await runPreScreen({ submissionId: this.recordId });
            this.statusMessage = 'Pre-screen running — results will appear below automatically.';
            this._startPolling();
        } catch (error) {
            this.isRunning = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: error.body ? error.body.message : error.message,
                variant: 'error'
            }));
        }
    }

    _startPolling() {
        this._pollTimer = setInterval(async () => {
            this._pollCount++;
            await this.loadResults();
            const done = this.results.length > 0 &&
                this.results.every(r => r.Processing_Status__c === 'Complete' || r.Processing_Status__c === 'Pending');
            if (done || this._pollCount >= POLL_MAX_ATTEMPTS) {
                this._clearPoll();
                this.isRunning = false;
                this.statusMessage = '';
                if (!done) {
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Still running',
                        message: 'Taking longer than expected. Try uploading the document again.',
                        variant: 'warning'
                    }));
                }
            }
        }, POLL_INTERVAL_MS);
    }

    _clearPoll() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }
}
