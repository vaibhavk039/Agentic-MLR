import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class MlrFileUpload extends LightningElement {
    @api recordId;
    @track uploadedFiles = [];

    acceptedFormats = ['.pdf', '.doc', '.docx', '.ppt', '.pptx', '.png', '.jpg', '.jpeg', '.txt'];

    handleUploadFinished(event) {
        const newFiles = event.detail.files;
        this.uploadedFiles = [...this.uploadedFiles, ...newFiles];
        this.dispatchEvent(new ShowToastEvent({
            title: 'Files Uploaded',
            message: `${newFiles.length} file(s) attached to this submission.`,
            variant: 'success'
        }));
    }

    get hasFiles() {
        return this.uploadedFiles.length > 0;
    }

    get uploadCount() {
        return this.uploadedFiles.length;
    }

    @api validate() {
        if (this.uploadedFiles.length === 0) {
            return {
                isValid: false,
                errorMessage: 'Please upload at least one document before continuing.'
            };
        }
        return { isValid: true };
    }
}
