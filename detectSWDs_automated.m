
function [ output, predictorMat ] = detectSWDs_automated(edffilespec, eventClassifier_filespec, fs, channel)
    % DETECTSWDS_AUTOMATED detects spike-and-wave discharge events from EEG
    % records. The detection algorithm works in 2 parts whereby likely events
    % are selected via a peak detection strategy using the normalized EEG and
    % the normalized first derivative of the EEG signal and then these events
    % are filtered using a support vector machine to decide yes/no events. This
    % unction requires:
    %
    % edffilespec: the path to an EDF file
    %
    % eventClassifier_filespec: the filepath to a trained classifier that
    % classifies events based on the predictors generated by
    % 'generatePredictorsForEventClassifier.m'. NOTE, you must have trained
    % this classifier prior to running this script.
    %
    % fs: the sample rate of the EDF file in question
    %
    % channel: the channel you wish to analyze (only 1 EEG channel allowed)
    %
    % This file creates a matrix of exactSeizureLocations which includes the 
    % yes/no SWD label along with signalClips around each identified event and
    % a matrix of predictors generated for each of those seizure locations.
    % Files generated from this script will be placed in the same folder as the
    % edffilespec.
    %
    % example:
    %
    % edffilespec = strcat(labDataDrive, '/jonesLab_data/sleep_and_seizures/EEG_data/RQ/EDFs/Ronde_4.edf');
    % eventClassifier_filespec = strcat(labDataDrive, '/jonesLab_data/sleep_and_seizures/EEG_data/RQ/SWDClassificationData/eventClassifier_RQSWDs.mat');
    % fs = 256;
    % channel = 2;
    % detectSWDs_automated(edffilespec, eventClassifier_filespec, fs, channel);
    %
    % JP 2017

    % import the signal and select a channel
    alreadyImportedEDF = read_EDF_mj(edffilespec);
    rSignal = alreadyImportedEDF.D.edf.eegData;
    rSignal = rSignal(:, channel);

    % find any blank parts of the EDF (singal == 0) and remove them from consideration for the normalization process
    goodEEGIndex = rSignal ~= 0;

    % normalize signal
    [~, rSig, modelfit, rMu] = normalizeEEG(rSignal(goodEEGIndex), fs);
    modelfit
    modelFitCuttoff = .85; % threshold for a decent model fit... If this too high there is likely something wonky about the EEG signal.
    if modelfit >= modelFitCuttoff % only continue if the fit is good.
        rSignal = (rSignal - rMu) / rSig;
        [~, rSig] = normalizeEEG(rSignal(goodEEGIndex), fs); % save the standard deviation of the signal for later use, note this should be 1.

        % calculate the first derivative of the signal and normalize that
        gSignal = gradient(rSignal);
        [~, gSig, ~, gMu] = normalizeEEG(gSignal(goodEEGIndex), fs);
        gSignal = (gSignal - gMu) / gSig;
        [~, gSig] = normalizeEEG(gSignal(goodEEGIndex), fs); % save the standard deviation of the signal for later use, note this should be 1.
        
        if gSig > 0 && rSig >0 

            % find peaks in the raw singal that are no wider apart than ~11Hz and have a larger amplitude than 3x the standard deviation of the raw signal (based on model fit)
            rMPH = 3 * rSig;
            rMPDFreq = 11.13;% Hz
            rMPD = floor(fs/rMPDFreq);
            [rPKS1, rLOCS1] = findpeaks( rSignal, 'MinPeakDistance', rMPD, 'MinPeakHeight', rMPH, 'Annotate','extents'); %

            % find peaks in the frist derivative of the raw signal
            gMPH = 3 * gSig;
            gMPDFreq = 21.33; % hz
            gMPD = floor(fs/gMPDFreq); % this designed to be more 'tolerant' than in the raw signal because the 11Hz criteria is kept with the peak locations from the raw signal
            [gPKS, gLOCS] = findpeaks(-gSignal, 'MinPeakHeight', gMPH, 'MinPeakDistance', gMPD, 'Annotate','extents');

            % set rules about which peaks are indicative of a SWD -- peak reduction
            lowerCuttoff = rMPD; % 11ish Hz
            upperCuttoffFreq = 3.16;
            upperCuttoff = floor(fs/upperCuttoffFreq); % approximately 3.16 Hz

            % this uses the lower and upper cuttoffs to remove points peaks the first derivative signal that don't occur within the approriate range
            gLOCS = [0 gLOCS' 0]; 
            gLOCStemp = zeros(1, length(gLOCS));
            for j = 2:length(gLOCS)-1
                crit1 = gLOCS(j) - gLOCS(j-1) > lowerCuttoff & gLOCS(j) - gLOCS(j-1) < upperCuttoff; 
                crit2 = gLOCS(j+1) - gLOCS(j) > lowerCuttoff & gLOCS(j+1) - gLOCS(j) < upperCuttoff;
                if crit1 || crit2
                     gLOCStemp(j) = 1;
                end
            end
            gLOCS = gLOCS(find(gLOCStemp));
            gPKS = gPKS(find(gLOCStemp(2:end-1)));

            % this uses the lower and upper cuttoffs to remove points from the raw signal signal
            rLOCS1 = [0 rLOCS1' 0]; 
            rLOCS1temp = zeros(1, length(rLOCS1));
                for j = 2:length(rLOCS1)-1
                    crit1 = rLOCS1(j) - rLOCS1(j-1) > lowerCuttoff & rLOCS1(j) - rLOCS1(j-1) < upperCuttoff; 
                    crit2 = rLOCS1(j+1) - rLOCS1(j) > lowerCuttoff & rLOCS1(j+1) - rLOCS1(j) < upperCuttoff;
                    if crit1 || crit2
                        rLOCS1temp(j) = 1;
                    end
                end
            rLOCS1 = rLOCS1(find(rLOCS1temp));
            rPKS1 = rPKS1(find(rLOCS1temp(2:end-1)));

            % takes the intersect of points between the gradient (first derivative) and raw signals (the peaks of these don't match perfectly so the buffer allows for the overlap)
            jointPeakBufferFreq = 17;
            jointPeakBuffer = floor(fs/jointPeakBufferFreq);
            rLOCSKeeperIndex = zeros(1, length(rLOCS1));
            for jj = 1:length(rLOCS1)
                temp = rLOCS1(jj);
                tempRange = temp:temp+jointPeakBuffer;
                interinter = intersect(gLOCS, tempRange);
                if length(interinter) == 1
                    rLOCSKeeperIndex(jj) = 1;
                end
            end

            % redistribute the location and peaks objects for later use 
            rLOCS1display = rLOCS1;
            rPKS1display = rPKS1;
            rLOCS1 = rLOCS1(find(rLOCSKeeperIndex));
            rPKS1 = rPKS1(find(rLOCSKeeperIndex));

            % create a matrix of potential events to be sorted later
            clear potentialEvents            
            temp = diff([0 rLOCS1]);
            potentialStarts = find(temp > upperCuttoff + floor(fs/10.24));
            nPotentialStarts = length(potentialStarts);

            if nPotentialStarts > 0         
            temp2 = [potentialStarts 0];
                for jj = 1:nPotentialStarts
                    if temp2(jj+1) == 0
                        endInd = length(rLOCS1);
                    else
                        endInd = temp2(jj+1) - 1 ; 
                    end
                potentialEvents(jj).localSeizureLOCS = rLOCS1(temp2(jj):endInd);
                potentialEvents(jj).globalSeizureLOCS = rLOCS1(temp2(jj):endInd);
                potentialEvents(jj).globalSeizurePKS = rPKS1(temp2(jj):endInd);
                end                       
            end

            % output the true seizure locations and pks
            zz = 1;
            if exist('potentialEvents', 'var')
                for jj = 1:length(potentialEvents)
                    output(zz).SWDLOCS = potentialEvents(jj).globalSeizureLOCS;
                    output(zz).SWDPKS = potentialEvents(jj).globalSeizurePKS;
                    zz = zz + 1;
                 end
            

                % filter these events to find seizures.   

                clear eventsObject
                lengthClip = fs * 8;
                for ii = 1:size(output, 2)
                    if output(ii).SWDLOCS(1) > lengthClip & output(ii).SWDLOCS(1) < length(rSignal) - lengthClip % drop events that are too close to the edge of the record
                        % add seizureDuration and signalClips to the outputMatrix
                        eventsObject(ii).seizureDuration = ceil(output(ii).SWDLOCS(end) - output(ii).SWDLOCS(1));
                        seizureCenterLocation = ceil(mean([output(ii).SWDLOCS(end), output(ii).SWDLOCS(1)]));
                        eventsObject(ii).signalClips = rSignal(seizureCenterLocation -(.5*lengthClip):seizureCenterLocation + (.5*lengthClip));
                        flag(ii) = 1;
                    else
                        flag(ii) = 0;
                    end

                end


                % if events exist then ouput the data
                if ~isempty(output) 

                    % this makes sure the output and the eventsObject match in length since I was an idiot and used 3 sepearate objects to house these events -- it's a holdover from a previous program and I didn't feel like reprograming it.
                    eventsObject = eventsObject(:,flag == 1);
                    output = output(:, flag == 1);

                    % generate predictors used to filter the events
                    predictorMat = generatePredictorsForEventClassifier(eventsObject, fs);

                    % load classifier and classify events
                    load(eventClassifier_filespec);
                    [classificationResponse, classificationScore] = trainedClassifier.predictFcn(predictorMat);

                    % convert all the classification scores to positive values.. the ifelse statments allow different types of classifiers to be used and convert properly
                    for i = 1:size(output, 2)
                        output(i).classificationResponse = classificationResponse(i);
                        if output(i).classificationResponse == 1
                            output(i).classificationScore = classificationScore(i, 1);
                        else
                            output(i).classificationScore = -classificationScore(i, 2);
                        end

                    end  

                    % export SWDFile
                    [a, b] = fileparts(edffilespec);
                    if exist('output', 'var')
                        save(char(strcat(labDataDrive, '/jonesLab_data/sleep_and_seizures/EEG_data/RQ/detectSWD_output/', b, '_exactSeizureLocations.mat')), 'output');
                    end
                    save(char(strcat(labDataDrive, '/jonesLab_data/sleep_and_seizures/EEG_data/RQ/detectSWD_output/', b, '_predictorMatrix.mat')), 'predictorMat');
                    close all

                end
            else
                 disp('No events found. Check Model fit if you expected events.')
            end
        else
            disp('Did not process data. The model fit produced a negative value for the standard deviation of the raw or the first derivative the the raw signal. WTF')
        end
    else
        disp('Did not process data. Model Fit for signal is poor. Check Signal for quality issues.')
    end
end

  