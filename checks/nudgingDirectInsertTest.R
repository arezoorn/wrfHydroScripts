suppressPackageStartupMessages(library(rwrfhydro))
options(warn=1)
trimws <- function (x, which = c("both", "left", "right")) 
{
    which <- match.arg(which)
    mysub <- function(re, x) sub(re, "", x, perl = TRUE)
    if (which == "left") 
        return(mysub("^[ \t\r\n]+", x))
    if (which == "right") 
        return(mysub("[ \t\r\n]+$", x))
    mysub("[ \t\r\n]+$", mysub("^[ \t\r\n]+", x))
}

## NOTE that right now the first time in the modeled timeseries is dropped:
## this is correct for cold starts. We could distinguish between restarts
# and cold starts?


## arguments are
## 1) runDir
## 2) OPTIONAL nCores, default=1, if > 1 runs in parallel using doMC
## 3) OPTIONAL mkPlot, default=FALSE. Only summary stats are printed. 
args <- commandArgs(TRUE)

runDir <- args[1]
if(is.na(runDir)) {
  cat("First argument 'runDir' is required\n")
  q(status=1)
}

nCores <- as.integer(args[2])
if(is.na(nCores)) nCores <- 1
## setup multicore
if(nCores > 1) {
  suppressPackageStartupMessages(library(doMC))
  registerDoMC(nCores)
}

## arg 2: outPath
mkPlot <- as.logical(args[3]) ## this can give NA as logical!
if(is.na(mkPlot) | class(mkPlot)!='logical') mkPlot <- FALSE

## does run dir exist?
if(!file.exists(runDir)) {
  cat("rundir: ", runDir, ' does not exist. Exiting.\n')
  q(status=1)
}

## distinguish between cold starts and restarts?

## For direct insertion with current temporal weighting function, 
## tau has to be less than NOAH timestep. Can we test if that's true?
## Bring in tau from nudgingParams.nc and compare to NOAH_TIMESTEP in namelist.hrldas.

CheckDirectInsert <- function(runDir, parallel=FALSE, modelTail=NA) {
  
  #############
  ## identify if frxst pts exists, if not only get model time range
  frxstFile <- list.files(runDir, pattern='frxst_pts_out.txt', full=TRUE)
  if(!length(frxstFile))
    frxstFile <- list.files(paste0(runDir,'/VERIFICATION'), pattern='frxst_pts_out.txt', full=TRUE)

  if(length(frxstFile)) {
    modelDf <- ReadFrxstPts(frxstFile)
    minModelTime <- min(modelDf$POSIXct)
    maxModelTime <- max(modelDf$POSIXct)
  } else {
    ## if not frxst_pts use CHRTOUT_DOMAIN
    chrtFiles <- list.files(runDir, pattern='CHRTOUT_DOMAIN', full=TRUE)
    if(!length(chrtFiles))
      chrtFiles <- list.files(paste0(runDir,'/VERIFICATION'), pattern='CHRTOUT_DOMAIN', full=TRUE)
    if(!is.na(modelTail)) chrtFiles <- tail(chrtFiles, modelTail)
    if(!length(chrtFiles))
      warning(paste0("Neither frxst_pts_out.txt nor *CHRTOUT_DOMAIN* files found in ",
                     runDir,' nor in ',runDir,'/VERIFICATION, please check.'),
              immediate.=TRUE)
    chrtTimes <- as.POSIXct(plyr::laply(strsplit(basename(chrtFiles),'\\.'),'[[', 1),
                            format='%Y%m%d%H%M', tz='UTC')
    minModelTime <- min(chrtTimes)
    maxModelTime <- max(chrtTimes)
  }

  #############
  ## identify the observations
  obsFiles <- list.files(paste0(runDir,'/nudgingTimeSliceObs'),
                         pattern='.15min.usgsTimeSlice.ncdf', full=TRUE)
  obsTimes <- as.POSIXct(substr(basename(obsFiles),1,19),
                         format='%Y-%m-%d_%H:%M:%S', tz='UTC')
  ## match up the obs and modeled pairs.
  ## strictly greater is correct for cold start runs as DA is not applied at the
  ## initial time.
  print(minModelTime)
  print(maxModelTime)
  whObsInModel <- which(obsTimes >  minModelTime &
                        obsTimes <= maxModelTime )
  obsDf <- plyr::ldply(obsFiles[whObsInModel], ReadNcTimeSlice, .parallel=parallel)
  print(nrow(obsDf))
  print(table(obsDf$dateTime))
              
  ## ###########
  ## if using CHRTOUT files, process the data after getting the obs in, to subset
  ## the full channel on to the obs as it is read in.
  if(!length(frxstFile)) {  
    ## need the routelink file to match the gages in ob
    ## parse hydro.namelist for the name of the Route_Link file.
    rlMatches <-
      gsub(" ","",grep('(route_link_f)',readLines(paste0(runDir,"/hydro.namelist")), value=TRUE))
    rlMatches <- grep('^[^!]*$', rlMatches, value=TRUE)
    rlFile <- strsplit(rlMatches,'\\"')[[1]][2]
    gages <- ncdump(paste0(runDir,'/',rlFile),'gages',quiet=TRUE)
    whGages <- which(gages %in% obsDf$site_no)
    ## loop through the stations, pulling each from the file individually?
    GetModeledGages <- function(chrtFile)
      data.frame(POSIXct=as.POSIXct(plyr::laply(strsplit(basename(chrtFile),'\\.'),'[[', 1),
                    format='%Y%m%d%H%M', tz='UTC'),
                 st_id=gages[whGages],
                 q_cms=ncdump(chrtFile, 'streamflow',quiet=TRUE)[whGages] )
    modelDf <- plyr::ldply(chrtFiles, GetModeledGages, .parallel=parallel)
    
  }


  
  ## match the obs to the model  
  ## 1) throw out obs which are not on the model times
  obsDf <- subset(obsDf, dateTime %in% modelDf$POSIXct)
  print(nrow(obsDf))
  ## 2) Throw out stations from the model which are not in the obs
  modelDf <- subset(modelDf, trimws(st_id) %in% trimws(obsDf$site_no))
  ## 3) Throw out stations from the obs which are not in the model
  obsDf <- subset(obsDf, trimws(site_no) %in% trimws(modelDf$st_id))
  ## a check: intersect(trimws(obsDf$site_no), trimws(modelDf$st_id))
  ## 4) prepare for merging: standardize the time and site variables
  names(obsDf)[which(names(obsDf)=='dateTime')] <- 'POSIXct'
  names(obsDf)[which(names(obsDf)=='site_no')] <- 'st_id'
  names(obsDf)[which(names(obsDf)=='code')] <- 'quality'
  modelDf$st_id <- trimws(modelDf$st_id)
  obsDf$st_id <- trimws(obsDf$st_id)
  names(modelDf)[which(names(modelDf)=='q_cms')] <- 'discharge.cms'
  obsDf$kind <- 'obs'
  modelDf$kind <- 'model'
  modelDf$quality <- NA
  
  
  ## 6
  theCols <- c('POSIXct','st_id','discharge.cms','kind','quality')
  comboDf <- rbind(obsDf[,theCols], modelDf[,theCols])

  ## pair
  ExtractPair <- function(dd) {
    if(nrow(dd) != 2) return(NULL)
    if(!(all(c("obs","model") %in% dd$kind))) {
      warning("repeats?")
      NULL
    }
    data.frame(POSIXct=dd$POSIXct[1],
               st_id=dd$st_id[1],
               obs=dd$discharge.cms[which(dd$kind=='obs')],
               obsQuality=dd$quality[which(dd$kind=='obs')],
               model=dd$discharge.cms[which(dd$kind=='model')], stringsAsFactors=FALSE)
  }
  pairDf <- plyr::ddply(comboDf, plyr::.(st_id, POSIXct), ExtractPair, .parallel=parallel)
  pairDf$err <- pairDf$model - pairDf$obs
  pairDf
}

## get the data
pairDf <- CheckDirectInsert(runDir, parallel=nCores > 1, modelTail=100)
pairDf <- within(pairDf,{pctErr=err/obs*100})

pairDf$validObs <- 'Invalid Obs'
pairDf$validObs[which(pairDf$obsQuality > 0)] <- 'Questionable Obs'
pairDf$validObs[which(pairDf$obsQuality == 100)] <- 'Valid Obs'
pairDf$pctErr[which(pairDf$validObs!='Valid Obs')] <- 0

invalTag <- paste0('Invalid Obs (n=',length(which(pairDf$validObs=='Invalid Obs')),')')
pairDf$validObs[which(pairDf$validObs=='Invalid Obs')] <- invalTag
questTag <- paste0('Questionable Obs (n=',length(which(pairDf$validObs=='Questionable Obs')),')')
pairDf$validObs[which(pairDf$validObs=='Questionable Obs')] <- questTag
validTag <- paste0('Valid Obs (n=',length(which(pairDf$validObs=='Valid Obs')),')')
pairDf$validObs[which(pairDf$validObs=='Valid Obs')] <- validTag

cat("\nThe number of observations nudged: ", nrow(pairDf),'\n')
cat("Quantiles of modeled-observed (errors) for nudging:\n")
print(format(quantile(subset(pairDf, validObs==validTag)$err, seq(0,1,.1)),
                      sci=FALSE), quote=FALSE)
cat("Quantiles of (modeled-observed)/observed (% errors) for nudging:\n")
print(format(quantile(subset(pairDf, validObs==validTag)$pctErr, seq(0,1,.1)),
             sci=FALSE), quote=FALSE)


pairDf$validObs <- as.factor(pairDf$validObs)

if(mkPlot) {
  ## check if the rundir is write protected, write it to ~ if it is.
  suppressPackageStartupMessages(library(ggplot2))
  #png('nudgingScatter_codeFreezeCheck.png',w=11*150,h=8.5*150, pointsize=8)
  pdf('nudgingScatter_codeFreezeCheck.pdf',w=11*1.2,h=8.5*1.2)
  ggplot(pairDf) +
    geom_abline(alpha=.5) +
    geom_point(data=subset(pairDf, validObs == validTag),
               aes(x=obs, y=model, color=pctErr, size=abs(pctErr)), shape=4) +
    geom_point(data=subset(pairDf, validObs!=validTag),
               aes(x=obs, y=model), shape=4, size=1.5) +
    facet_wrap(~validObs, scales='free', ncol=3) +
    theme_bw(base_size=21) +
    scale_colour_gradientn(colours = rainbow(6)) +
    scale_size_continuous(range=c(1.5,6)) +
    coord_fixed(ratio=1) +
    ggtitle(paste0('Obs vs Nudged:',
                   paste(format(range(pairDf$POSIXct),'%Y-%m-%d %H:%M'),collapse=' - ')))
  dev.off()
  
}

retValue <- if(any(abs(subset(pairDf, validObs=='Valid Obs')$err)   >.001 | 
                   abs(subset(pairDf, validObs=='Valid Obs')$pctErr)>2.5 
                   )) 1 else 0

q(status=retValue)
