library("dplyr")
library("tidyr")

#Read different datasets from disk
transcript_data = tbl_df(readRDS("annotations/Homo_sapiens.GRCh38.78.transcript_data.rds"))
refseq_data = tbl_df(readRDS("annotations/Homo_sapiens.GRCh38.78.refseq_data.rds"))
transcript_tags = read.table("annotations/Homo_sapiens.GRCh38.78.transcript_tags.txt", stringsAsFactors = FALSE)

#Extract transcript tags
colnames(transcript_tags) = c("ensembl_transcript_id", "tags")
tag_list = strsplit(transcript_tags$tags, ";")
names(tag_list) = transcript_tags$ensembl_transcript_id

#Build a data.frame of transcript tags
tags_df = transmute(transcript_data, ensembl_transcript_id,  CCDS = 0, mRNA_start_NF = 0, mRNA_end_NF = 0, cds_start_NF = 0, cds_end_NF = 0, seleno = 0)
tags_df = data.frame(tags_df)
rownames(tags_df) = tags_df$ensembl_transcript_id

#Put tags into the data frame
#NOTE: This will take a while...
tx_ids = names(tag_list)
for (tx_id in tx_ids){
  print(tx_id)
  tags_df[tx_id, tag_list[[tx_id]] ] = 1
}
saveRDS(tbl_df(tags_df), "annotations/Homo_sapiens.GRCh38.78.tags_dataframe.rds")

#Add transcript tags into the data.frame
tags_df = readRDS("annotations/Homo_sapiens.GRCh38.78.tags_dataframe.rds")
tags_df = dplyr::select(tags_df, ensembl_transcript_id, mRNA_start_NF:cds_end_NF)

#Convert TSL to integer
trimmed_tsl = dplyr::select(transcript_data, ensembl_transcript_id, transcript_tsl) %>% 
  tidyr::separate(transcript_tsl, into = c("transcript_tsl", "version"), sep = "\\s\\(", extra = "drop") %>% 
  dplyr::select(ensembl_transcript_id, transcript_tsl) %>%
  dplyr::mutate(transcript_tsl = ifelse(transcript_tsl == "", "tslNA", transcript_tsl)) %>% #Convert empty TSLs into NAs 
  tidyr::separate(transcript_tsl, into = c("none","tsl"), sep ="tsl", extra = "drop", convert = TRUE) %>% 
  dplyr::select(ensembl_transcript_id, tsl)

#Add refseq ids 
refseq_ids = dplyr::mutate(refseq_data, refseq_id_count = ifelse(refseq_mrna == "", 0, 1)) %>% 
  dplyr::group_by(ensembl_transcript_id) %>% 
  dplyr::summarise(refseq_id_count = sum(refseq_id_count), refseq_ids = paste(refseq_mrna, collapse = ";"))

#Add APPRIS annotations
appris_data = read.table("annotations/appris_data.principal.txt", stringsAsFactors = FALSE)
colnames(appris_data)[3:5] = c("ensembl_transcript_id", "CCDS", "appris_status")
appris_data = appris_data %>% dplyr::tbl_df() %>% dplyr::select(ensembl_transcript_id, appris_status)

#Put all of the data together
compiled_data = dplyr::left_join(transcript_data, tags_df, by = "ensembl_transcript_id") %>% #Add transcript flags
  dplyr::mutate(mRNA_start_end_NF = mRNA_start_NF + mRNA_end_NF) %>%
  dplyr::mutate(cds_start_end_NF = cds_start_NF + cds_end_NF) %>%
  dplyr::left_join(trimmed_tsl, by = "ensembl_transcript_id") %>% #Add TSL 
  dplyr::left_join(refseq_ids, by = "ensembl_transcript_id") %>% #Add RefSeq ids
  dplyr::left_join(appris_data, by = "ensembl_transcript_id") %>% #Add APPRIS flags
  dplyr::mutate(is_ccds = ifelse(ccds == "", 0, 1)) %>%
  dplyr::mutate(is_gencode_basic = ifelse(transcript_gencode_basic == "",0,1))

#Count CCDS and GENCODE basic annotations per gene
compiled_data = dplyr::group_by(compiled_data, ensembl_gene_id) %>% 
  dplyr::summarize(n_ccds = sum(is_ccds), n_gencode_basic = sum(is_gencode_basic)) %>% 
  dplyr::left_join(compiled_data, by = "ensembl_gene_id")

#Filter annotations
valid_chromosomes = c("1","10","11","12","13","14","15","16","17","18","19",
                      "2","20","21","22","3","4","5","6","7","8","9","MT","X","Y")
valid_gene_biotypes = c("lincRNA","protein_coding","IG_C_gene","IG_D_gene","IG_J_gene",
                        "IG_V_gene", "TR_C_gene","TR_D_gene","TR_J_gene", "TR_V_gene")

filtered_data = dplyr::filter(compiled_data, chromosome_name %in% valid_chromosomes, 
                         gene_biotype %in% valid_gene_biotypes,
                         transcript_biotype %in% valid_gene_biotypes) %>%
                         #Flag transcripts that are potenitally good references
                         dplyr::mutate(is_good_reference = ifelse(cds_start_end_NF == 0, is_gencode_basic, 0)) 
  

#For each gene mark the transcripts with longest starts and ends
by_tx_start = dplyr::filter(filtered_data, is_good_reference == 1) %>% 
  dplyr::group_by(ensembl_gene_id) %>% 
  dplyr::arrange(transcript_start) %>% #Find smallest possible transcript_start coordinate
  dplyr::select(ensembl_gene_id, ensembl_transcript_id, strand,transcript_start) %>% 
  dplyr::filter(row_number() == 1) %>% 
  dplyr::ungroup() %>%
  #Use strand infromation to decide whether it is at the start or the end of the transcript
  dplyr::transmute(ensembl_transcript_id, longest_start = sign(strand +1), longest_end = sign(abs(strand-1)))

by_tx_end = dplyr::filter(filtered_data, is_good_reference == 1) %>% 
  dplyr::group_by(ensembl_gene_id) %>% 
  dplyr::arrange(desc(transcript_end)) %>% #Find largest possible transcript_end coordinate
  dplyr::select(ensembl_gene_id, ensembl_transcript_id, strand, transcript_end) %>% 
  dplyr::filter(row_number() == 1) %>% 
  dplyr::ungroup() %>%
  #Use strand infromation to decide whether it is at the start or the end of the transcript
  dplyr::transmute(ensembl_transcript_id, longest_start = sign(abs(strand-1)), longest_end = sign(strand +1))

#Combine the start and end coordinates
both_ends = dplyr::left_join(filtered_data, by_tx_start, by = "ensembl_transcript_id") %>% 
  dplyr::left_join(by_tx_end, by = "ensembl_transcript_id") %>%
  dplyr::transmute(ensembl_transcript_id, 
            longest_start = ifelse(is.na(longest_start.x), 0, longest_start.x) + ifelse(is.na(longest_start.y), 0, longest_start.y),
            longest_end = ifelse(is.na(longest_end.x), 0, longest_end.x) + ifelse(is.na(longest_end.y), 0, longest_end.y))

marked_data = dplyr::left_join(filtered_data, both_ends, by = "ensembl_transcript_id")

