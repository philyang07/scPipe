
#########################################################################
# Generating the Feature Matrix from a Given BAM file and a Feature FIle
#########################################################################

#' @name sc_atac_feature_counting
#' @title generating the feature by cell matrix 
#' @description feature matrix is created using a given demultiplexed BAM file and 
#' a selected feature type
#' @param insortedbam The input bam
#' @param feature_input The feature input data
#' @param bam_tags The BAM tags
#' @param feature_type The type of feature
#' @param organism The organism type
#' @param cell_calling The desired cell calling method
#' @param genome_size The size of the genome
#' @param promoters_file The path of the promoter annotation file (if the specified organism isn't recognised)
#' @param tss_file The path of the tss annotation file (if the specified organism isn't recognised)
#' @param enhs_file The path of the enhs annotation file (if the specified organism isn't recognised)
#' @param bin_size The size of the bins
#' @param yieldsize The yield size
#' @param mapq The minimum MAPQ score
#' @param exclude_regions Whether or not the regions should be excluded
#' @param exclude_regions_filename The filename of the file containing the regionsn to be excluded
#' @param output_folder The output folder
#' @param fix_chr Whether chr should be fixed or not
#' 
#' @param lower the lower threshold for the data if using the \code{emptydrops} function for cell calling.
#'
#' @param min_uniq_frags The minimum number of required unique fragments required for a cell (used for \code{filter} cell calling)
#' @param max_uniq_frags The maximum number of required unique fragments required for a cell (used for \code{filter} cell calling)
#' @param min_frac_peak The minimum proportion of fragments in a cell to overlap with a peak (used for \code{filter} cell calling)
#' @param min_frac_tss The minimum proportion of fragments in a cell to overlap with a tss (used for \code{filter} cell calling)
#' @param min_frac_enhancer The minimum proportion of fragments in a cell to overlap with a enhancer sequence (used for \code{filter} cell calling)
#' @param min_frac_promoter The minimum proportion of fragments in a cell to overlap with a promoter sequence (used for \code{filter} cell calling)
#' @param max_frac_mito The maximum proportion of fragments in a cell that are mitochondrial (used for \code{filter} cell calling)
#' 
#' @importFrom BiocGenerics start end which strand start<- end<-
#' @import dplyr
#' @import tidyr
#' 
#' @export
#' 

sc_atac_feature_counting <- function(
  insortedbam, 
  feature_input  = NULL, 
  bam_tags       = list(bc="CB", mb="OX"), 
  feature_type   = "peak", 
  organism       = NULL,
  cell_calling   = FALSE, # either c("cellranger", "emptydrops", "filter")
  genome_size    = NULL, # this is optional but needed if the cell_calling option is cellranger AND organism in NULL
  promoters_file = NULL,
  tss_file       = NULL,
  enhs_file      = NULL,
  bin_size       = NULL, 
  yieldsize      = 1000000,
  mapq           = 30,
  exclude_regions= FALSE, 
  excluded_regions_filename = NULL,
  output_folder  = NULL,
  fix_chr        = "none", # should be either one of these: c("none", "excluded_regions", "feature", "both")
  lower = NULL,
  min_uniq_frags = 0,
  max_uniq_frags = 50000,
  min_frac_peak = 0.05,
  min_frac_tss = 0,
  min_frac_enhancer = 0,
  min_frac_promoter = 0,
  max_frac_mito = 0.2
) {
  
  init_time = Sys.time()
  
  available_organisms = c("hg19",
                          "hg38",
                          "mm10")
  
  if(!is.null(organism)) stopifnot(organism %in% available_organisms)
  
  stopifnot(fix_chr %in% c("none", "excluded_regions", "feature", "both"))
  
  if(is.null(output_folder)) {
    output_folder <- file.path(getwd(), "scPipe-atac-output")
    cat("Output directory has not been provided. Saving output in\n", output_folder, "\n")
  }
  
  if (!dir.exists(output_folder)){
    dir.create(output_folder,recursive=TRUE)
    cat("Output directory does not exist. Creating...", output_folder, "\n")
  }
  
  
  # initiate log file and location for stats in scPipe_atac_stats
  log_and_stats_folder <- paste0(output_folder, "/scPipe_atac_stats/")
  dir.create(log_and_stats_folder, showWarnings = FALSE)
  log_file             <- paste0(log_and_stats_folder, "log_file.txt")
  stats_file           <- paste0(log_and_stats_folder, "stats_file_align.txt")
  if(!file.exists(log_file)) file.create(log_file)
  # file.create(stats_file)
  
  # timer
  cat(
    paste0(
      "sc_atac_feature_counting starts at ",
      as.character(Sys.time()),
      "\n"
    ), 
    file = log_file, append = TRUE)
  
  ############# feature type is genome_bin ####################
  
  if(feature_type == 'genome_bin'){
    # TODO: test the format of the fasta file here and stop if not proper format
    cat("`genome bin` feature type is selected for feature input. reading the genome fasta file ...", "\n")
    
    # index for feature_input is created if not found in the same directory as the feature_input
    if(!file.exists(paste0(feature_input,".fai"))){
      Rsamtools::indexFa(feature_input)
      cat("Index for ", feature_input, " is being created... ", "\n")
    }
    
    if(is.null(bin_size)){
      bin_size <- 2000
      cat("Default bin size of 2000 is selected", "\n")
    }
    
    out_bed_filename <- paste0(output_folder, "/", sub('\\..[^\\.]*$', '', basename(feature_input)), ".bed") # remove extension and append output folder
    
    if(file.exists(out_bed_filename)) {
      message(out_bed_filename, " file already exists. Replacing!")
      file.remove(out_bed_filename)
    }
    
    if(!is.null(feature_input)){
      
      rcpp_fasta_bin_bed_file(feature_input, out_bed_filename, bin_size)
      
      # Check if file was created
      if(file.exists(out_bed_filename)) {
        cat("Generated the genome bin file:\n", out_bed_filename, "\n")
      }
      else {
        stop("File ", out_bed_filename, "file was not created.")
      }
      
      ## End if is.null
    } else{
      if(!is.null(organism)){
        
        # Use organism data sizes saved in repository
        organism_files     <- list.files(system.file("extdata/annotations/", package = "scPipe", mustWork = TRUE))
        sizes_filename_aux <- grep(pattern = organism, x = organism_files, value = TRUE) %>% 
          grep(pattern     <- "size", x = ., value = TRUE)
        
        sizes_filename <- system.file(paste0("extdata/annotations/", sizes_filename_aux), package = "scPipe", mustWork = TRUE)
        
        sizes_df <- read.table(sizes_filename, header = FALSE, col.names = c("V1", "V2"))
        
        sizes_df_aux <- sizes_df %>% 
          dplyr::group_by(V1) %>% 
          dplyr::mutate(V3 = floor(V2/bin_size),
                        V4 = bin_size*V3) %>% 
          dplyr::ungroup()
        
        
        
        out_bed <- purrr::map_df(1:nrow(sizes_df_aux), function(i){
          
          aux_i        <- sizes_df_aux %>% dplyr::slice(i)
          seq_aux_end  <- seq(from = bin_size, to = aux_i$V4, by = bin_size)
          seq_aux_init <- seq_aux_end - bin_size + 1
          
          if(seq_aux_end[length(seq_aux_end)] == aux_i$V2){
            last_row_init <- c()
            last_row_end  <- c()
          } else{
            last_row_init <- seq_aux_end[length(seq_aux_end)] + 1
            last_row_end  <- aux_i$V2
          }
          
          options(scipen = 999) # To prevent scientific notation
          out_df <- dplyr::tibble(init = c(seq_aux_init, last_row_init), 
                                  end = c(seq_aux_end, last_row_end)
          ) %>% 
            dplyr::mutate(name = aux_i$V1, .before = init)
          
          return(out_df)
        })
        
        write.table(out_bed, file = out_bed_filename, row.names = FALSE, col.names = FALSE, quote = FALSE, sep = "\t")
        
        # Check if file was created
        if(file.exists(out_bed_filename)) {
          cat("Generated the genome bin file:\n", out_bed_filename, "\n")
        }
        else {
          stop("File ", out_bed_filename, "file was not created.")
        }
      } else{
        stop("Either organism or feature_input should be provided.")
      }
    } # End else is.null(genome_size)
    
    # feature_input <- genome_bin
  }
  
  ############################## feature type is peak #####################
  if(feature_type == 'peak' || feature_type == 'tss' || feature_type == 'gene'){
    cat("`peak`, `tss` or `gene` feature_type is selected for feature input", "\n")
    
    ############################### fix_chr in feature file
    if(fix_chr %in% c("feature", "both")){
      
      out_bed_filename_feature <- paste0(output_folder, "/", 
                                         sub('\\..[^\\.]*$', 
                                             '', 
                                             basename(feature_input)
                                         ), "_fixedchr.bed"
      ) # remove extension and append output folder
      
      # Try to read first 5 rows of feature_input file to see if the format is correct
      feature_head <- read.table(feature_input, nrows = 5)
      if(ncol(feature_head) < 3){
        warning("Feature file provided does not contain 3 columns. Cannot append chr")
        break;
      }
      
      
      rcpp_append_chr_to_bed_file(feature_input, out_bed_filename_feature)
      
      # Check if file was created
      if(file.exists(out_bed_filename_feature)) {
        cat("Appended 'chr' to feature file and output created in:", out_bed_filename_feature, "\n")
        feature_input <- out_bed_filename_feature
      }
      else {
        stop("File ", out_bed_filename_feature, "file was not created.")
      }
      
    }
    
    ############################### fix_chr in excluded regions
    if(fix_chr %in% c("excluded_regions", "both")){
      if(!is.null(excluded_regions_filename)){
        
        out_bed_filename_excluded_regions <- paste0(output_folder, "/", 
                                                    sub('\\..[^\\.]*$', 
                                                        '', 
                                                        basename(excluded_regions_filename)
                                                    ), "_fixedchr.bed"
        ) # remove extension and append output folder
        
        # Try to read first 5 rows of excluded_regions file to see if the format is correct
        excluded_regions_head <- read.table(excluded_regions_filename, nrows = 5)
        if(ncol(excluded_regions_head) < 3){
          warning("excluded_regions file provided does not contain 3 columns. Cannot append chr")
          break
        }
        
        rcpp_append_chr_to_bed_file(excluded_regions_filename, out_bed_filename_excluded_regions)
        
        # Check if file was created
        if(file.exists(out_bed_filename_excluded_regions)) {
          cat("Appended 'chr' to excluded_regions file and output created in:", out_bed_filename_excluded_regions, "\n")
          excluded_regions_filename <- out_bed_filename_excluded_regions
        }
        else {
          stop("File ", out_bed_filename_excluded_regions, "file was not created.")
        }
      }
    
    } # end if excluded_regions
  }
  
  ############################### end fix_chr
  
  ###################### generate the GAlignment objects from BAM and features ######################
  
  ############## read in the aligned and demultiplexed BAM file
  
  cat("Creating GAlignment object for the sorted BAM file...\n")
  
  param <- Rsamtools::ScanBamParam(tag = as.character(bam_tags),  mapqFilter=mapq)
  bamfl <- Rsamtools::BamFile(insortedbam, yieldSize = yieldsize)
  open(bamfl)
  
  yld                            <- GenomicAlignments::readGAlignments(bamfl,use.names = TRUE, param = param)
  yld.gr                         <- GenomicRanges::makeGRangesFromDataFrame(yld,keep.extra.columns=TRUE) 
  average_number_of_lines_per_CB <- length(yld.gr$CB)/length(unique(yld.gr$CB))
  
  ############# Adjusting for the Tn5 cut site
  cat("Adjusting for the 9bp Tn5 cut site...\n")
  
  isMinus <- BiocGenerics::which(strand(yld.gr) == "-")
  isOther <- BiocGenerics::which(strand(yld.gr) != "-")
  #Forward
  start(yld.gr)[isOther] <- start(yld.gr)[isOther] - 5
  end(yld.gr)[isOther] <- end(yld.gr)[isOther] + 4
  #Reverse
  end(yld.gr)[isMinus] <- end(yld.gr)[isMinus] + 5
  start(yld.gr)[isMinus] <- start(yld.gr)[isMinus] - 4
  
  saveRDS(yld.gr, file = paste(output_folder,"/BAM_GAlignmentsObject.rds",sep = ""))
  cat("GAlignment object is created and saved in \n", paste(output_folder,"/BAM_GAlignmentsObject.rds",sep = "") , "\n")
  
  ############## generate the GAalignment file from the feature_input file
  cat("Creating Galignment object for the feature input...\n")
  if(feature_type != 'genome_bin'){
    feature.gr <- rtracklayer::import(feature_input)
  } else {
    feature.gr <- rtracklayer::import(out_bed_filename)
  }
  
  ############################### exclude regions 
  
  number_of_lines_to_remove <- 0
  
  if(exclude_regions){
    
    if(is.null(excluded_regions_filename) & !is.null(organism)){
      ## If excluded_regions_filename is null but organism is not, then read the file from system
      
      organism_files                <- list.files(system.file("extdata/annotations/", package = "scPipe", mustWork = TRUE))
      excluded_regions_filename_aux <- grep(pattern = organism, x = organism_files, value = TRUE) %>% 
        grep(pattern = "blacklist", x = ., value = TRUE)
      excluded_regions_filename     <- system.file(paste0("extdata/annotations/", excluded_regions_filename_aux), package = "scPipe", mustWork = TRUE)
    } 
    
    if(!is.null(excluded_regions_filename)){
      excluded_regions.gr               <- rtracklayer::import(excluded_regions_filename)
      overlaps_excluded_regions_feature <- IRanges::findOverlaps(excluded_regions.gr, feature.gr, maxgap = -1L, minoverlap = 0L) # Find overlaps
      lines_to_remove                   <- as.data.frame(overlaps_excluded_regions_feature)$subjectHits # Lines to remove in feature file
      number_of_lines_to_remove         <- length(lines_to_remove)
      
      if(number_of_lines_to_remove > 0){ # If there are lines to remove
        feature.gr.df            <- as.data.frame(feature.gr)
        lines_to_keep            <- setdiff(1:nrow(feature.gr.df), lines_to_remove)
        feature.gr               <- feature.gr[lines_to_keep, ]
      } # End if(number_of_lines_to_remove > 0)
      
    } else{
      warning("Parameter exclude_regions was TRUE but no known organism or excluded_regions_filename provided. Proceding without excluding regions.")
    }
    
    
  } # End if(exclude_regions)
  
  ################# Initiate log file
  log_and_stats_folder       <- paste0(output_folder, "/scPipe_atac_stats/")
  dir.create(log_and_stats_folder, showWarnings = FALSE)
  log_file                   <- paste0(log_and_stats_folder, "log_file.txt")
  if(!file.exists(log_file)) file.create(log_file)
  
  cat("Average number of reads per CB:", average_number_of_lines_per_CB, "\n", 
      file = log_file, append = TRUE)
  
  cat("Number of regions removed from feature_input:", number_of_lines_to_remove, "\n", 
      file = log_file, append = TRUE)
  
  ############### Overlaps
  median_feature_overlap <- median(GenomicAlignments::ranges(feature.gr)@width)
  minoverlap             <- 0.51*median_feature_overlap
  maxgap                 <- 0.51*median_feature_overlap
  
  overlaps               <- GenomicAlignments::findOverlaps(query         = feature.gr, # feature.gr,
                                                            subject       = yld.gr, # yld.gr, #
                                                            type          = "equal", 
                                                            maxgap        = maxgap, 
                                                            #minoverlap   = minoverlap, 
                                                            ignore.strand = TRUE)
  
  # generate the matrix using this overlap results above.
  
  mcols(yld.gr)[subjectHits(overlaps), "peakStart"] <- start(GenomicAlignments::ranges(feature.gr)[queryHits(overlaps)])
  mcols(yld.gr)[subjectHits(overlaps), "peakEnd"]   <- end(GenomicAlignments::ranges(feature.gr)[queryHits(overlaps)])
  
  #is removing NAs here the right thing to do?
  overlap.df <- data.frame(yld.gr) %>% filter(!is.na(peakStart)) %>% select(seqnames, peakStart, peakEnd, CB)
  
  overlap.df <- overlap.df %>% 
    group_by(seqnames, peakStart, peakEnd, CB) %>% 
    summarise(count = n()) %>% 
    purrr::set_names(c("chromosome","start","end","barcode","count")) %>% 
    unite("chrS", chromosome:start, sep=":") %>%
    unite("feature", chrS:end, sep="-")
  
  matrixData <- overlap.df %>%
    group_by(feature,barcode) %>% 
    spread(barcode, count)
  
  matrixData           <- as.data.frame(matrixData)
  rownames(matrixData) <- matrixData$feature
  
  matrixData.old       <- matrixData
  matrixData           <- matrixData %>%
    dplyr::select(-1) %>%
    data.table::as.data.table() %>%
    Biostrings::as.matrix() %>%
    replace(is.na(.), 0)
  
  # add dimensions of the matrix
  dimnames(matrixData)  <-  list(matrixData.old[1] %>% rownames(), matrixData.old %>% dplyr::select(-1) %>% colnames())
  
  saveRDS(matrixData, file = paste(output_folder,"/unfiltered_feature_matrix.rds",sep = ""))
  cat("Raw feature matrix generated: ", paste(output_folder,"/unfiltered_feature_matrix.rds",sep = "") , "\n")
  Matrix::writeMM(Matrix::Matrix(matrixData), file = paste(output_folder,"/unfiltered_feature_matrix.mtx",sep = ""))
  
  # Check if organism is pre-recognized and if so then use the package's annotation files
  if (organism %in% c("hg19", "hg38", "mm10")) {
    cat(organism, "is a recognized organism. Using annotation files in repository.\n")
    anno_paths <- system.file("extdata/annotations/", package = "scPipe", mustWork = TRUE)
    promoters_file <- file.path(anno_paths, paste0(organism, "_promoter.bed"))
    tss_file <- file.path(anno_paths, paste0(organism, "_tss.bed"))
    enhs_file <- file.path(anno_paths, paste0(organism, "_enhancer.bed"))
  }
  else if (!all(file.exists(c(promoters_file, tss_file, enhs_file)))) {
    stop("One of the annotation files could not be located. Please make sure their paths are valid.")
  }
  
  # generate qc_per_bc_file
  sc_atac_create_qc_per_bc_file(inbam = insortedbam, 
                                frags_file = file.path(output_folder, "fragments.bed"),
                                peaks_file = file.path(output_folder, "NA_peaks.narrowPeak"),
                                promoters_file = promoters_file,
                                tss_file = tss_file,
                                enhs_file = enhs_file,
                                output_folder = output_folder)
  
  qc_per_bc_file <- file.path(output_folder, "qc_per_bc_file.txt")
  
  # Cell calling
  matrixData <- sc_atac_cell_calling(mat = matrixData, 
                                     cell_calling = cell_calling, 
                                     output_folder = output_folder, 
                                     genome_size = genome_size, 
                                     qc_per_bc_file = qc_per_bc_file, 
                                     lower = lower,
                                     min_uniq_frags = min_uniq_frags,
                                     max_uniq_frags = max_uniq_frags,
                                     min_frac_peak = min_frac_peak,
                                     min_frac_tss = min_frac_tss,
                                     min_frac_enhancer = min_frac_enhancer,
                                     min_frac_promoter = min_frac_promoter,
                                     max_frac_mito = max_frac_mito)
  
  
  # converting the NAs to 0s if the sparse option to create the sparse Matrix properly
  sparseM <- Matrix::Matrix(matrixData, sparse=TRUE)
  # add dimensions of the sparse matrix if available
  if(cell_calling != FALSE){
    barcodes <- read.table(paste0(output_folder, '/non_empty_barcodes.txt'))$V1
    features <- read.table(paste0(output_folder, '/non_empty_features.txt'))$V1
    dimnames(sparseM) <- list(features, barcodes)
  }
  
  cat("Sparse matrix generated", "\n")
  saveRDS(sparseM, file = paste(output_folder, "/sparse_matrix.rds", sep = ""))
  Matrix::writeMM(obj = sparseM, file=paste(output_folder, "/sparse_matrix.mtx", sep =""))
  cat("Sparse count matrix is saved in\n", paste(output_folder,"/sparse_matrix.mtx",sep = "") , "\n")
  
  # generate and save jaccard matrix
  jaccardM <- locStra::jaccardMatrix(sparseM)
  cat("Jaccard matrix generated", "\n")
  saveRDS(jaccardM, file = paste(output_folder,"/jaccard_matrix.rds",sep = ""))
  cat("Jaccard matrix is saved in\n", paste(output_folder,"/jaccard_matrix.rds",sep = "") , "\n")
  
  # generate and save the binary matrix
  matrixData[matrixData>0] <- 1
  saveRDS(matrixData, file = paste(output_folder,"/binary_matrix.rds",sep = ""))
  cat("Binary matrix is saved in:\n", paste(output_folder,"/binary_matrix.rds",sep = "") , "\n")
  
  # following can be used to plot the stats and load it into sce object ########
  # (from https://broadinstitute.github.io/2020_scWorkshop/data-wrangling-scrnaseq.html)
  counts_per_cell    <- Matrix::colSums(sparseM)
  counts_per_feature <- Matrix::rowSums(sparseM)
  features_per_cell  <- Matrix::colSums(sparseM>0)
  cells_per_feature  <- Matrix::rowSums(sparseM>0)
  
  # generating the data frames for downstream use 
  info_per_cell <- data.frame(counts_per_cell = counts_per_cell) %>% 
    tibble::rownames_to_column(var = "cell") %>% 
    full_join(
      data.frame(features_per_cell = features_per_cell) %>% 
        tibble::rownames_to_column(var = "cell"),
      by = "cell"
    )
  
  info_per_feature <- data.frame(counts_per_feature = counts_per_feature) %>% 
    tibble::rownames_to_column(var = "feature") %>% 
    full_join(
      data.frame(cells_per_feature = cells_per_feature) %>% 
        tibble::rownames_to_column(var = "feature"),
      by = "feature"
    )
  


  write.csv(info_per_cell, paste0(log_and_stats_folder, "filtered_stats_per_cell.csv"), row.names = FALSE)
  write.csv(info_per_feature, paste0(log_and_stats_folder, "filtered_stats_per_feature.csv"), row.names = FALSE)
  
  end_time = Sys.time()
  
  print(end_time - init_time)
  
  cat(
    paste0(
      "sc_atac_counting finishes at ",
      as.character(Sys.time()),
      "\n\n"
    ), 
    file = log_file, append = TRUE)
  
}
  
#' @name sc_atac_generate_per_ber_pc_file
#' @title generating a file useful for producing the qc plots
#' @description uses the peak file and annotation files for features
#' @param inbam The input bam file
#' @param frags_file The fragment file
#' @param peaks_file The peak file
#' @param promoters_file The path of the promoter annotation file 
#' @param tss_file The path of the tss annotation file 
#' @param enhs_file The path of the enhs annotation file 
#' @param output_folder
#' 
#' @param lower the lower threshold for the data if using the \code{emptydrops} function for cell calling.
#' 
#' @param min_uniq_frags The minimum number of required unique fragments required for a cell (used for \code{filter} cell calling)
#' @param max_uniq_frags The maximum number of required unique fragments required for a cell (used for \code{filter} cell calling)
#' @param min_frac_peak The minimum proportion of fragments in a cell to overlap with a peak (used for \code{filter} cell calling)
#' @param min_frac_tss The minimum proportion of fragments in a cell to overlap with a tss (used for \code{filter} cell calling)
#' @param min_frac_enhancer The minimum proportion of fragments in a cell to overlap with a enhancer sequence (used for \code{filter} cell calling)
#' @param min_frac_promoter The minimum proportion of fragments in a cell to overlap with a promoter sequence (used for \code{filter} cell calling)
#' @param max_frac_mito The maximum proportion of fragments in a cell that are mitochondrial (used for \code{filter} cell calling)
#' 
#' @importFrom data.table fread setkey copy
#' 
#' @export
#' 
sc_atac_create_qc_per_bc_file <- function(inbam, 
                                          frags_file,
                                          peaks_file,
                                          promoters_file,
                                          tss_file,
                                          enhs_file,
                                          output_folder,
                                          lower = NULL,
                                          min_uniq_frags = 0,
                                          max_uniq_frags = 50000,
                                          min_frac_peak = 0.05,
                                          min_frac_tss = 0,
                                          min_frac_enhancer = 0,
                                          min_frac_promoter = 0,
                                          max_frac_mito = 0.2) {
  
  
  sourceCpp(code='
    #include <Rcpp.h>
    using namespace Rcpp;
    // for each read, return 1 if it overlap with any region, otherwise 0;
    // should sort both reads and regions
    // [[Rcpp::export]]
    IntegerVector getOverlaps_read2AnyRegion(DataFrame reads, DataFrame regions) {
      NumericVector start1 = reads["start"];
      NumericVector end1 = reads["end"];
      NumericVector start2 = regions["start"];
      NumericVector end2 = regions["end"];
          
      int n1 = start1.size(), n2 = start2.size();
      NumericVector midP1(n1), len1(n1), len2(n2), midP2(n2);
      IntegerVector over1(n1);
          
      len1 = (end1 - start1 + 1)/2;
      midP1 = (end1 + start1)/2;
          
      len2 = (end2 - start2 + 1)/2;
      midP2 = (end2 + start2)/2;
      int k = 0;
      for(int i=0; i<n1; i++){
        over1[i] = 0;
        for(int j=k; j<n2; j++){
         if((fabs(midP1[i] - midP2[j]) <= (len1[i]+len2[j]))){
            over1[i] = 1;
            k = j;
            break;
          }
        }
      }
          
      return(over1);
    }
    
    // [[Rcpp::export]]
    NumericVector getOverlaps_read2AllRegion(DataFrame reads, DataFrame regions) {
      NumericVector start1 = reads["start"];
      NumericVector end1 = reads["end"];
          
      NumericVector start2 = regions["start"];
      NumericVector end2 = regions["end"];
          
      int n1 = start1.size(), n2 = start2.size();
      NumericVector midP1(n1), len1(n1), len2(n2), midP2(n2);
      NumericVector over1(n1);
          
      len1 = (end1 - start1 + 1)/2;
      midP1 = (end1 + start1)/2;
          
      len2 = (end2 - start2 + 1)/2;
      midP2 = (end2 + start2)/2;
      int j = 0;
      int k = 0;
 
      if(start1[0] > end2[n2-1] || end1[n1-1] < start2[0]) {
          return(over1);
      }
      
      for(int i=0; i<n1; i++){
        while (k<n2 && fabs(midP1[i] - midP2[k]) > (len1[i]+len2[k])){
          k++;
        }
        // the kth element is the first element overlapped with the current fragment
        // take advantage of sorted fragments and regions, for next fragment,
        // it will start searching from kth region
        j=k;
        
        // current frag not overlapped any region then search from beginning
        if(j >= n2 -1) k = 0, j = 0;  
        while (j<n2 && fabs(midP1[i] - midP2[j]) <= (len1[i]+len2[j])){
          over1[i] = over1[i] + 1;
          j++;
        }
      }
          
      return(over1);
    }
  
  // [[Rcpp::export]]
  NumericVector getOverlaps_tss2Reads(DataFrame regions, DataFrame left_flank, DataFrame reads) {
    NumericVector start1 = regions["start"];
        
    int n = start1.size();
    NumericVector over(n), left_over(n);
    NumericVector tss_enrich_score(n);
    over = getOverlaps_read2AllRegion(regions, reads);
    left_over = getOverlaps_read2AllRegion(left_flank, reads);
    tss_enrich_score = (over+1.0) / (left_over+1.0) ;
    return(tss_enrich_score);
  }    
  ')
  
  out.frag.overlap.file <- file.path(output_folder, "qc_per_bc_file.txt")
  
  frags <- fread(frags_file, select=1:4, header = F)
  names(frags) <- c('chr', 'start', 'end', 'bc')
  setkey(frags, chr, start)
  
  frags[, 'total_frags' := .N, by = bc]
  frags <- frags[total_frags > 5]
  
  frags <- frags[!grepl(chr, pattern = 'random', ignore.case = T)]
  frags <- frags[!grepl(chr, pattern ='un', ignore.case = T)]
  
  peaks <- fread(peaks_file, select=1:3, header = F)
  promoters <- fread(promoters_file, select=1:3, header = F)
  tss <- fread(tss_file, select=1:3, header = F)
  enhs <- fread(enhs_file, select=1:3, header = F)
  names(peaks) = names(promoters) = names(tss) =
    names(enhs) = c('chr', 'start', 'end')
  
  
  setkey(peaks, chr, start)
  setkey(promoters, chr, start)
  setkey(tss, chr, start)
  setkey(enhs, chr, start)
  
  chrs <- unique(frags$chr)
  
  ## calculate tss enrichment score
  if(T){
    set.seed(2021)
    tss4escore <- copy(tss)
    if(nrow(tss) > 40000) tss4escore <- tss[sort(sample(1:nrow(tss), 40000))]
    setkey(tss4escore, chr, start)
    
    tss4escore <- unique(tss4escore)
    tss4escore.left <- copy(tss4escore)
    tss4escore[, 'start' := start - 50]
    tss4escore[, 'end' := start + 100]
    tss4escore.left[, 'start' := start - 1950]
    tss4escore.left[, 'end' := start + 100]
    
    bcs <- unique(frags$bc)
    escores <- rep(1, length(bcs))
    names(escores) <- bcs
    frags4escore <- frags[total_frags >= 1000] ## only caculate tss_escore for selected bc
    
    for(bc0 in unique(frags4escore$bc)){
      frags0 <- frags4escore[bc == bc0]
      chrs0 <- unique(frags0$chr)
      tss4escore0 <- tss4escore[chr %in% chrs0]
      tss4escore0.left <- tss4escore.left[chr %in% chrs0]
      chrs <- unique(frags0$chr)
      escores_chrs <- NULL
      for(chr0 in chrs0){
        if(nrow(frags0[chr==chr0]) <= 50) next
        escores_chrs[chr0] <- max(getOverlaps_tss2Reads(tss4escore0[chr==chr0], 
                                                       tss4escore0.left[chr==chr0],
                                                       frags0[chr==chr0]))
      }
      
      escores[bc0] <- max(escores_chrs)
    }
    escores <- escores + runif(length(escores), 0, 0.1)
    rm(frags4escore, frags0, tss4escore, tss4escore.left)
  }
  
  
  tss[, 'start' := start - 1000]
  tss[, 'end' := end + 1000]
  fragsInRegion <- NULL
  for(chr0 in chrs){
    peaks0 <- peaks[chr == chr0]
    promoters0 <- promoters[chr == chr0]
    
    tss0 <- tss[chr == chr0]
    enhs0 <- enhs[chr == chr0]
    frags0 <- frags[chr == chr0]
    frags <- frags[chr != chr0]
    if(nrow(peaks0) == 0){
      frags0[, 'peaks' := 0]
    }else{
      frags0[, 'peaks' := getOverlaps_read2AnyRegion(frags0, peaks0)]
    }
    
    if(nrow(promoters0) == 0){
      frags0[, 'promoters' := 0]
    }else{
      frags0[, 'promoters' := getOverlaps_read2AnyRegion(frags0, promoters0)]
    }
    
    if(nrow(tss0) == 0){
      frags0[, 'tss' := 0]
    }else{
      frags0[, 'tss' := getOverlaps_read2AnyRegion(frags0, tss0)]
    }
    
    if(nrow(enhs0) == 0){
      frags0[, 'enhs' := 0]
    }else{
      frags0[, 'enhs' := getOverlaps_read2AnyRegion(frags0, enhs0)]
    }
    
    
    fragsInRegion <- rbind(fragsInRegion, frags0)
    message(paste(chr0, 'Done!'))
  }
  rm(frags)
  
  # get barcode region count matrix
  fragsInRegion[, 'isMito' := ifelse(chr %in% c('chrM'), 1, 0)]
  fragsInRegion[, c('chr', 'start', 'end') := NULL]
  fragsInRegion[, 'frac_mito' := sum(isMito)/total_frags, by = bc]
  fragsInRegion[, 'isMito' := NULL]
  fragsInRegion[, 'frac_peak' := sum(peaks)/total_frags, by = bc]
  fragsInRegion[, 'peaks' := NULL]
  fragsInRegion[, 'frac_promoter' := sum(promoters)/total_frags, by = bc]
  fragsInRegion[, 'promoters' := NULL]
  fragsInRegion[, 'frac_tss' := sum(tss)/total_frags, by = bc]
  fragsInRegion[, 'tss' := NULL]
  fragsInRegion[, 'frac_enhancer' := sum(enhs)/total_frags, by = bc]
  fragsInRegion[, 'enhs' := NULL]
  fragsInRegion <- unique(fragsInRegion)
  fragsInRegion$tss_enrich_score <- escores[fragsInRegion$bc]
  
  write.table(fragsInRegion, file = out.frag.overlap.file, sep = '\t',
              row.names = F, quote = F)
}


