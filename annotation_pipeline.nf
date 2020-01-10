#!/usr/bin/env nextflow
/*
 * Author:
 * - Trestan Pillonel <trestan.pillonel@gmail.com>
 *
 */


// Each Sample
if (params.ncbi_sample_sheet != false){
  Channel.fromPath( file(params.ncbi_sample_sheet) )
                      .splitCsv(header: true, sep: '\t')
                      .map{ row -> "$row.Genbank" } 
                      .into{ assembly_accession_list }

  Channel.fromPath( file(params.ncbi_sample_sheet) )
                      .splitCsv(header: true, sep: '\t')
                      .map{ row -> "$row.RefSeq" }
                      .set{ assembly_accession_list_refseq }

}

process prokka {
	publishDir 'data/prokka_output', mode: 'copy', overwrite: true

	// NOTE : according to Prokka documentation, a linear acceleration
	// is obtained up to 8 processes and after that, the overhead becomes
	// more important
	cpus 8

	when:
	params.prokka

	input:
	file genome_fasta from Channel.fromPath(params.fna_dir + "/*.fna")

	output:
	file "prokka_results/*.gbk" into gbk_from_local_assembly

	script:
	"""
	prokka $genome_fasta --outdir prokka_results --prefix ${genome_fasta.baseName} \\
		 --centre X --compliant --cpus ${task.cpus}
	"""
}

// leave all the contigs with no coding region (check_gbk doesn't like them)
process prokka_filter_CDS {
	publishDir 'data/prokka_output_filtered', mode: 'copy', overwrite: true
	input:
	file prokka_file from gbk_from_local_assembly.collect()

	when:
	params.prokka

	output:
	file "*_filtered.gbk" into gbk_prokka_filtered

	script:
	"""
	#!/usr/bin/env python
	
	import annotations

	gbk_files = "${prokka_file}".split()
	for i in gbk_files:
		annotations.filter_out_unannotated(i)
	"""
}

if(!params.prokka) {
	gbk_prokka_filtered = Channel.empty()
}


if(params.local_sample_sheet){
	local_genomes = Channel.fromPath(params.local_sample_sheet)
				  .splitCsv(header: true, sep: '\t')
				  .map{row -> "$row.gbk_path" }
				  .map { file(it) }
} else {
	local_genomes = Channel.empty()
} 

process copy_local_assemblies {
    publishDir 'data/gbk_local', mode: 'copy', overwrite: true

    cpus 1

    when:
    params.local_sample_sheet || params.prokka

	// Mixing inputs from local assemblies annotated with Prokka
	// and local annotated genomes in .gbk format
    input:
    file local_gbk from local_genomes.mix(gbk_prokka_filtered.flatMap())

    output:
    file "${local_gbk}.gz" into raw_local_gbffs

    script:
    """
    gzip -f ${local_gbk}
    """
}

if(!params.prokka && !params.local_sample_sheet) {
	raw_local_gbffs = Channel.empty()	
}

if(params.ncbi_sample_sheet == false) {
	raw_ncbi_gbffs = Channel.empty()
}else {
  
  // TODO : create a single query to the database
  process download_assembly {

    // conda 'biopython=1.73'

    publishDir 'data/gbk_ncbi', mode: 'copy', overwrite: true

    maxForks 2
    maxRetries 3
    //errorStrategy 'ignore'

    when:
    params.ncbi_sample_sheet

    input:
    each accession from assembly_accession_list

    cpus 1

    output:
    file '*.gbff.gz' into raw_ncbi_gbffs

    script:
    //accession = assembly_accession[0]
    """
	#!/usr/bin/env python
	import annotations
	annotations.download_assembly("$accession")
    """
  }

  // TODO: create a single query to the database
  process download_assembly_refseq {

    // conda 'biopython=1.73'

    publishDir 'data/refseq_corresp', mode: 'copy', overwrite: true

    maxForks 2
    maxRetries 3
    //errorStrategy 'ignore'

    echo false

    when:
    params.ncbi_sample_sheet && params.get_refseq_locus_corresp

    input:
    each accession from assembly_accession_list_refseq

    cpus 1

    output:
    file '*.gbff.gz' optional true into raw_ncbi_gbffs_refseq

    script:
    //accession = assembly_accession[0]
    """
	#!/usr/bin/env python
	import annotations
	annotations.download_assembly_refseq("$accession")
    """
  }

  process refseq_locus_mapping {

    conda 'biopython=1.73'

    publishDir 'data/refseq_corresp', mode: 'copy', overwrite: true

    maxForks 2
    maxRetries 3
    //errorStrategy 'ignore'

    echo false

    when:
    params.get_refseq_locus_corresp == true

    input:
    file accession_list from raw_ncbi_gbffs_refseq.collect()

    cpus 1

    output:
    file 'refseq_corresp.tab'

    script:
    """
	#!/usr/bin/env python
	import annotations
	accessions_list = "$accession_list".split(' ')
	annotations.refseq_locus_mapping(accessions_list)
    """
  }
}

all_raw_gbff = raw_ncbi_gbffs.mix(raw_local_gbffs)

process gbk_check {
  publishDir 'data/gbk_edited', mode: 'copy', overwrite: true

  // conda 'bioconda::biopython=1.68'

  cpus 2

  input:
  file all_gbff from all_raw_gbff.collect()

  output:
  file "*merged.gbk" into edited_gbks

  script:
  """
  #!/usr/bin/env python
  
  import annotations
  annotations.check_gbk("$all_gbff".split())
  """
}

process convert_gbk_to_faa {

  publishDir 'data/faa_locus', mode: 'copy', overwrite: true

  // conda 'bioconda::biopython=1.68'

  echo false

  cpus 1

  input:
  each file(edited_gbk) from edited_gbks

  output:
  file "*.faa" into faa_files

  script:
  """
	#!/usr/bin/env python
	import annotations

	annotations.convert_gbk_to_faa("${edited_gbk}", "${edited_gbk.baseName}.faa")
  """
}

faa_files.into{ faa_locus1; faa_locus2 }


faa_locus1.into { faa_genomes1
                  faa_genomes2
                  faa_genomes3
                  faa_genomes4
                  faa_genomes5
                  faa_genomes6 }

faa_locus2.collectFile(name: 'merged.faa', newLine: true)
    .set { merged_faa0 }


process get_nr_sequences {

  // conda 'bioconda::biopython=1.68'

  publishDir 'data/', mode: 'copy', overwrite: true

  input:
  file(seq) from merged_faa0
  file genome_list from faa_genomes4.collect()

  output:

  file 'nr.faa' into nr_seqs
  file 'nr_mapping.tab' into nr_mapping

  script:
  fasta_file = seq.name
  """
	#!/usr/bin/env python
	
	import annotations
	annotations.get_nr_sequences("${fasta_file}", "${genome_list}".split())
  """
}

nr_seqs.collectFile(name: 'merged_nr.faa', newLine: true)
.into { merged_faa_chunks
        merged_faa1
        merged_faa2
        merged_faa3
        merged_faa4
        merged_faa5
        merged_faa6
        merged_faa7 }

merged_faa_chunks.splitFasta( by: 1000, file: "chunk_" )
.into { faa_chunks1
        faa_chunks2
        faa_chunks3
        faa_chunks4
        faa_chunks5
        faa_chunks6
        faa_chunks7
        faa_chunks8
        faa_chunks9 }

process prepare_orthofinder {

  // conda 'bioconda::orthofinder=2.2.7'

  when:
  params.orthofinder

  input:
    file genome_list from faa_genomes1.collect()

  output:
    file "OrthoFinder/Results_$params.orthofinder_output_dir/WorkingDirectory/Species*.fa" into species_fasta
    file "OrthoFinder/Results_$params.orthofinder_output_dir/WorkingDirectory/BlastDBSpecies*.phr" into species_blastdb
    path "OrthoFinder/Results_$params.orthofinder_output_dir/" into result_dir

  script:
  """
  orthofinder -op -a 8 -n "$params.orthofinder_output_dir" -S blast -f . > of_prep.tab
  """
}

process blast_orthofinder {

  // conda 'bioconda::blast=2.7.1'

  cpus 2

  input:
  file complete_dir from result_dir
  each seq from species_fasta
  each blastdb from species_blastdb


  when:
  params.orthofinder

  output:
  file "${complete_dir.baseName}/WorkingDirectory/Blast${species_1}_${species_2}.txt" into blast_results
  

  script:
  blastdb_name = blastdb.getBaseName()
  blastdb_path = blastdb.getParent()
  seq_name = seq.getBaseName()
  species_1 =  (seq_name =~ /Species(\d+)/)[0][1]
  species_2 =  (blastdb_name =~ /BlastDBSpecies(\d+)/)[0][1]

  """
  blastp -outfmt 6 -evalue 0.001 -query $seq -db $blastdb_path/$blastdb_name -num_threads ${task.cpus} > ${complete_dir}/WorkingDirectory/Blast${species_1}_${species_2}.txt
  """
}

process orthofinder_main {

  // conda 'bioconda::orthofinder=2.2.7'

  publishDir 'orthology', mode: 'copy', overwrite: true
  echo true

  cpus 8

  input:
  file complete_dir from result_dir
  val blast_results from blast_results.collect()

  output:
  // for some reason, executing orthofinder on previous blast results makes it change directory
  // and output its results in the new directory... TODO : fixit!
  file "Results_$params.orthofinder_output_dir/WorkingDirectory/OrthoFinder/Results_$params.orthofinder_output_dir/Orthogroups/Orthogroups.txt" into orthogroups
  file "Results_$params.orthofinder_output_dir/WorkingDirectory/OrthoFinder/Results_$params.orthofinder_output_dir/Orthogroups/Orthogroups_SingleCopyOrthologues.txt" into singletons

  script:
  """
  echo "${complete_dir.baseName}"
  ls
  orthofinder -og -t ${task.cpus} -a ${task.cpus} \
	-b ./Results_$params.orthofinder_output_dir/WorkingDirectory/ > of_grouping.txt \
	-n "$params.orthofinder_output_dir"
  """
}

orthogroups
.into { orthogroups_1
        orthogroups_2}

process orthogroups2fasta {
  // conda 'bioconda::biopython=1.70'

  publishDir 'orthology/orthogroups_fasta', mode: 'copy', overwrite: true

  input:
  file 'Orthogroups.txt' from orthogroups_1
  file genome_list from faa_genomes2.collect()

  output:
  file "*faa" into orthogroups_fasta

  """
	#!/usr/bin/env python
	import annotations
	annotations.orthogroups_to_fasta("$genome_list")
  """
}


process align_with_mafft {

  // conda 'bioconda::mafft=7.407'

  publishDir 'orthology/orthogroups_alignments', mode: 'copy', overwrite: true

  input:
  file og from orthogroups_fasta.flatten().collate( 20 )

  output:
  file "*_mafft.faa" into mafft_alignments

  script:
  """
  unset MAFFT_BINARIES
  for faa in ${og}; do
  mafft \$faa > \${faa/.faa/_mafft.faa}
  done
  """
}

/* Get only alignments with more than than two sequences */
mafft_alignments.collect().into {all_alignments_1
                                 all_alignments_2
                                 all_alignments_3
                                 all_alignments_4}

all_alignments_1.flatten().map { it }.filter { (it.text =~ /(>)/).size() > 3 }.set { alignments_larget_tah_3_seqs }
all_alignments_2.flatten().map { it }.filter { (it.text =~ /(>)/).size() == 3 }.set { alignments_3_seqs }
all_alignments_4.flatten().map { it }.filter { (it.text =~ /(>)/).size() > 2 }.set { alignement_larger_than_2_seqs }

/*
process orthogroups_phylogeny_with_raxml {

  echo false
  // conda 'bioconda::raxml=8.2.9'
  cpus 4
  publishDir 'orthology/orthogroups_phylogenies', mode: 'copy', overwrite: false

  input:
  each file(og) from large_alignments

  output:
    file "${og}.nwk"

  script:
  """
  raxmlHPC -m PROTGAMMALG -p 12345 -s ${og} -n ${og.getBaseName()} -c 4 -T 4;
  raxmlHPC -f J -m PROTGAMMALG -s ${og} -p 12345 -t RAxML_result.${og.getBaseName()} -n sh_test_${og.getBaseName()} -T 4
  """
}
*/

process orthogroups_phylogeny_with_fasttree3 {

  // conda 'bioconda::fasttree=2.1.10'
  cpus 4
  publishDir 'orthology/orthogroups_phylogenies_fasttree', mode: 'copy', overwrite: true

  when:
  params.orthogroups_phylogeny_with_fasttree

  input:
  each file(og) from alignement_larger_than_2_seqs

  output:
    file "${og.baseName}.nwk"

  script:
  """
  FastTree ${og} > ${og.baseName}.nwk
  """
}


process orthogroups_phylogeny_with_iqtree {

  conda 'bioconda::iqtree=1.6.8'
  cpus 2
  publishDir 'orthology/orthogroups_phylogenies_iqtree', mode: 'copy', overwrite: true

  when:
  params.orthogroups_phylogeny_with_iqtree == true

  input:
  each file(og) from alignments_larget_tah_3_seqs

  output:
    file "${og.getBaseName()}.iqtree"
    file "${og.getBaseName()}.treefile"
    file "${og.getBaseName()}.log"
    file "${og.getBaseName()}.bionj"
    file "${og.getBaseName()}.ckp.gz"
    file "${og.getBaseName()}.mldist"
    file "${og.getBaseName()}.model.gz"
    file "${og.getBaseName()}.splits.nex"

  script:
  """
  iqtree -nt 2 -s ${og} -alrt 1000 -bb 1000 -pre ${og.getBaseName()}
  """
}

process orthogroups_phylogeny_with_iqtree_no_boostrap {

  conda 'bioconda::iqtree=1.6.8'
  cpus 2
  publishDir 'orthology/orthogroups_phylogenies_iqtree', mode: 'copy', overwrite: true

  when:
  params.orthogroups_phylogeny_with_iqtree == true

  input:
  each file(og) from alignments_3_seqs

  output:
    file "${og.getBaseName()}.iqtree"
    file "${og.getBaseName()}.treefile"
    file "${og.getBaseName()}.log"
    file "${og.getBaseName()}.bionj"
    file "${og.getBaseName()}.ckp.gz"
    file "${og.getBaseName()}.mldist"
    file "${og.getBaseName()}.model.gz"

  script:
  """
  iqtree -nt 2 -s ${og} -pre ${og.getBaseName()}
  """
}

process get_core_orthogroups {

  // conda 'bioconda::biopython=1.68 anaconda::pandas=0.23.4'
  cpus 1
  memory '16 GB'
  echo false
  publishDir 'orthology/core_groups', mode: 'copy', overwrite: true

  input:
  file 'Orthogroups.txt' from orthogroups
  file genomes_list from faa_genomes3.collect()
  file fasta_files from all_alignments_3.collect()

  output:
  file '*_taxon_ids.faa' into core_orthogroups

  script:

  """
  #!/usr/bin/env python
  import annotations
  genomes_list = "$genomes_list".split()
  annotations.get_core_orthogroups(genomes_list, int("${params.core_missing}"))
  """
}

process concatenate_core_orthogroups {

  // conda 'bioconda::biopython=1.68 anaconda::pandas=0.23.4'

  publishDir 'orthology/core_alignment_and_phylogeny', mode: 'copy', overwrite: true

  input:
  file core_groups from core_orthogroups.collect()

  output:
  file 'msa.faa' into core_msa

  script:

  """
  #!/usr/bin/env python
  import annotations
  fasta_files = "${core_groups}".split(" ")
  annotations.concatenate_core_orthogroups(fasta_files)

  """
}

process build_core_phylogeny_with_fasttree {

  // conda 'bioconda::fasttree=2.1.10'

  publishDir 'orthology/core_alignment_and_phylogeny', mode: 'copy', overwrite: true

  when:
  params.core_genome_phylogeny_with_fasttree

  input:
  file 'msa.faa' from core_msa

  output:
  file 'core_genome_phylogeny.nwk'

  script:
  '''
  FastTree -gamma -spr 4 -mlacc 2 -slownni msa.faa > core_genome_phylogeny.nwk
  '''
}


/* process checkm_analyse {
  '''
  Get fasta file of each orthogroup
  '''

  // conda 'bioconda::checkm-genome=1.0.12'

  publishDir 'data/checkm/analysis', mode: 'copy', overwrite: true

  when:
  params.checkm == true

  input:
  file genome_list from faa_genomes5.collect()

  output:
  file "checkm_results/*" into checkm_analysis

  """
  checkm analyze --genes -x faa \$CHECKM_SET_PATH . checkm_results -t 8 --nt
  """
}


process checkm_qa {
  '''
  Get fasta file of each orthogroup
  '''

  conda 'bioconda::checkm-genome=1.0.12'

  publishDir 'data/checkm/analysis', mode: 'copy', overwrite: true

  when:
  params.checkm == true

  input:
  file checkm_analysis_results from checkm_analysis

  output:
  file "checkm_results.tab" into checkm_table

  """
  checkm qa \$CHECKM_SET_PATH . -o 2 --tab_table > checkm_results.tab
  """
} */


process rpsblast_COG {

  // conda 'bioconda::blast=2.7.1'

  cpus 4

  when:
  params.cog == true

  input:
  file 'seq' from faa_chunks1

  output:
  file 'blast_result' into blast_result

  script:
  n = seq.name
  """
  rpsblast -db $params.databases_dir/cdd/profiles/Cog -query seq -outfmt 6 -evalue 0.001 -num_threads ${task.cpus} > blast_result
  """
}

blast_result.collectFile(name: 'annotation/COG/blast_COG.tab')

process blast_swissprot {

  // conda 'bioconda::blast=2.7.1'

  publishDir 'annotation/blast_swissprot', mode: 'copy', overwrite: true

  cpus 4

  when:
  params.blast_swissprot

  input:
  file(seq) from faa_chunks3

  output:
  file '*tab' into swissprot_blast

  script:

  n = seq.name
  """
  blastp -db $params.databases_dir/uniprot/swissprot/uniprot_sprot.fasta -query ${n} -outfmt 6 -evalue 0.001  -num_threads ${task.cpus} > ${n}.tab
  """
}


process plast_refseq {

  publishDir 'annotation/plast_refseq', mode: 'copy', overwrite: true

  cpus 12

  when:
  params.plast_refseq == true

  input:
  file(seq) from faa_chunks5

  output:
  file '*tab' into refseq_plast
  file '*log' into refseq_plast_log

  script:

  n = seq.name
  """
  # 15'000'000 vs 10'000'000
  # 100'000'000 max
  # -s 45
  export PATH="\$PATH:\$PLAST_HOME"
  plast -p plastp -a ${task.cpus} -d $params.databases_dir/refseq/merged.faa.pal -i ${n} -M BLOSUM62 -s 60 -seeds-use-ratio 45 -max-database-size 50000000 -e 1e-5 -G 11 -E 1 -o ${n}.tab -F F -bargraph -verbose -force-query-order 1000 -max-hit-per-query 200 -max-hsp-per-hit 1 > ${n}.log;
  """
}

process diamond_refseq {

  publishDir 'annotation/diamond_refseq', mode: 'copy', overwrite: true

  cpus 4
  // conda 'bioconda::diamond=0.9.24'

  when:
  params.diamond_refseq

  input:
  file(seq) from faa_chunks6

  output:
  file '*tab' into refseq_diamond

  script:

  n = seq.name
  """
  diamond blastp -p ${task.cpus} -d $params.databases_dir/refseq/merged_refseq.dmnd -q ${n} -o ${n}.tab --max-target-seqs 200 -e 0.01 --max-hsps 1
  """
}

refseq_diamond.collectFile().set { refseq_diamond_results_sqlitedb }


//refseq_diamond_results_taxid_mapping
//.splitCsv(header: false, sep: '\t')
//.map{row ->
//    def protein_accession = row[1]
//    return "${protein_accession}"
//}
//.unique()
//.collectFile(name: 'nr_refseq_hits.tab', newLine: true)
//.set {refseq_diamond_nr}

//.collate( 300 )
//.set {
//    nr_refseq_hits_chunks
//}

process get_uniparc_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/uniparc_mapping/', mode: 'copy', overwrite: true

  when:
  params.uniparc == true

  input:
  file(seq) from merged_faa1

  output:
  file 'uniparc_mapping.tab' into uniparc_mapping_tab
  file 'uniprot_mapping.tab' into uniprot_mapping_tab
  file 'no_uniprot_mapping.faa' into no_uniprot_mapping_faa
  file 'no_uniparc_mapping.faa' into no_uniparc_mapping_faa
  file 'uniparc_mapping.faa' into uniparc_mapping_faa

  script:
  fasta_file = seq.name
  """
	#!/usr/bin/env python
	import annotations
	annotations.get_uniparc_mapping("$database_dir", "$fasta_file")
  """
}

uniparc_mapping_tab.into{
  uniparc_mapping_tab1
  uniparc_mapping_tab2
}

uniprot_mapping_tab.into{
  uniprot_mapping_tab1
  uniprot_mapping_tab2
}

uniprot_mapping_tab2.splitCsv(header: true, sep: '\t')
.map{row -> "\"$row.uniprot_accession\"" }.unique().set { uniprot_nr_accessions }

process get_uniprot_data {

  conda 'biopython=1.73=py36h7b6447c_0'

  publishDir 'annotation/uniparc_mapping/', mode: 'copy', overwrite: true
  echo true

  when:
  params.uniprot_data == true

  input:
  file(table) from uniprot_mapping_tab1

  output:
  file 'uniprot_data.tab' into uniprot_data

  script:
  	"""
	#!/usr/bin/env python3.6
	import annotations
	annotations.get_uniprot_data("${params.databases_dir}", "${table}")
	"""
}


process get_uniprot_proteome_data {

  conda 'biopython=1.73=py36h7b6447c_0'

  publishDir 'annotation/uniparc_mapping/', mode: 'copy', overwrite: true
  echo true

  when:
  params.uniprot_data == true

  input:
  file "uniprot_data.tab" from uniprot_data

  output:
  file 'uniprot_match_annotations.db' into uniprot_db

  script:
  """
  uniprot_annotations.py
  """
}


process get_string_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/string_mapping/', mode: 'copy', overwrite: true

  when:
  params.string == true

  input:
  file(seq) from merged_faa2


  output:
  file 'string_mapping.tab' into string_mapping

  script:
  fasta_file = seq.name
  """
	#!/usr/bin/env python
	import annotations

	annotations.get_string_mapping("${fasta_file}", "${params.databases_dir}")
  """
}

process get_string_PMID_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/string_mapping/', mode: 'copy', overwrite: true

  when:
  params.string == true

  input:
  file(string_map) from string_mapping


  output:
  file 'string_mapping_PMID.tab' into string_mapping_BMID

  script:

  """
	#!/usr/bin/env python
	import annotations
	annotations.get_string_PMID_mapping("${string_map}")
  """
}


process get_PMID_data {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/string_mapping/', mode: 'copy', overwrite: true

  when:
  params.string == true

  input:
  file 'string_mapping_PMID.tab' from string_mapping_BMID


  output:
  file 'string_mapping_PMID.db' into PMID_db

  script:

  """
#!/usr/bin/env python

from Bio import Entrez
import sqlite3

Entrez.email = "trestan.pillonel@chuv.ch"


def chunks(l, n):
    for i in range(0, len(l), n):
        yield l[i:i+n]


def pmid2abstract_info(pmid_list):
    from Bio import Medline

    # make sure that pmid are strings
    pmid_list = [str(i) for i in pmid_list]

    try:
        handle = Entrez.efetch(db="pubmed", id=','.join(pmid_list), rettype="medline", retmode="text")
        records = Medline.parse(handle)
    except:
        print("FAIL:", pmid)
        return None

    pmid2data = {}
    for record in records:
      try:
          pmid = record["PMID"]
      except:
          print(record)
          #{'id:': ['696885 Error occurred: PMID 28696885 is a duplicate of PMID 17633143']}
          if 'duplicate' in record['id:']:
              duplicate = record['id:'].split(' ')[0]
              correct = record['id:'].split(' ')[-1]
              print("removing duplicated PMID... %s --> %s" % (duplicate, correct))
              # remove duplicate from list
              pmid_list.remove(duplicate)
              return pmid2abstract_info(pmid_list)

      pmid2data[pmid] = {}
      pmid2data[pmid]["title"] = record.get("TI", "?")
      pmid2data[pmid]["authors"] = record.get("AU", "?")
      pmid2data[pmid]["source"] = record.get("SO", "?")
      pmid2data[pmid]["abstract"] = record.get("AB", "?")
      pmid2data[pmid]["pmid"] = pmid

    return pmid2data

conn = sqlite3.connect("string_mapping_PMID.db")
cursor = conn.cursor()

sql = 'create table if not exists hash2pmid (hash binary, ' \
      ' pmid INTEGER)'

sql2 = 'create table if not exists pmid2data (pmid INTEGER, title TEXT, authors TEXT, source TEXT, abstract TEXT)'
cursor.execute(sql,)
cursor.execute(sql2,)

# get PMID nr list and load PMID data into sqldb
pmid_nr_list = []
sql_template = 'insert into hash2pmid values (?, ?)'
with open("string_mapping_PMID.tab", "r") as f:
    n = 0
    for row in f:
        data = row.rstrip().split("\t")
        if data[1] != 'None':
            n+=1
            cursor.execute(sql_template, data)
            if data[1] not in pmid_nr_list:
                pmid_nr_list.append(data[1])
        if n % 1000 == 0:
            print(n, 'hash2pmid ---- insert ----')
            conn.commit()

pmid_chunks = [i for i in chunks(pmid_nr_list, 50)]

# get PMID data and load into sqldb
sql_template = 'insert into pmid2data values (?, ?, ?, ?, ?)'
for n, chunk in enumerate(pmid_chunks):
    print("pmid2data -- chunk %s / %s" % (n, len(pmid_chunks)))
    pmid2data = pmid2abstract_info(chunk)
    for pmid in pmid2data:
        cursor.execute(sql_template, (pmid, pmid2data[pmid]["title"], str(pmid2data[pmid]["authors"]), pmid2data[pmid]["source"], pmid2data[pmid]["abstract"]))
    if n % 10 == 0:
        conn.commit()
conn.commit()
  """
}


process get_tcdb_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/tcdb_mapping/', mode: 'copy', overwrite: true

  when:
  params.tcdb == true

  input:
  file(seq) from merged_faa3


  output:
  file 'tcdb_mapping.tab' into tcdb_mapping
  file 'no_tcdb_mapping.faa' into no_tcdb_mapping

  script:
  fasta_file = seq.name
  """
	#!/usr/bin/env python
	
	import annotations
	annotations.get_tcdb_mapping("${fasta_file}", "${params.databases_dir}")
  """
}

no_tcdb_mapping.splitFasta( by: 1000, file: "chunk" )
.set { faa_tcdb_chunks }

process tcdb_gblast3 {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  publishDir 'annotation/tcdb_mapping', mode: 'copy', overwrite: true

  cpus 1
  maxForks 20

  echo false

  when:
  params.tcdb_gblast == true

  input:
  file(seq) from faa_tcdb_chunks

  output:
  file 'TCDB_RESULTS_*' into tcdb_results

  script:

  n = seq.name
  """
  # activate conda env
  source activate gblast3
  /usr/local/bin/BioVx/scripts/gblast3.py -i ${seq} -o TCDB_RESULTS_${seq} --db_path /usr/local/bin/tcdb_db/
  """
}

process get_pdb_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/pdb_mapping/', mode: 'copy', overwrite: true

  when:
  params.pdb == true

  input:
  file(seq) from merged_faa4


  output:
  file 'pdb_mapping.tab' into pdb_mapping
  file 'no_pdb_mapping.faa' into no_pdb_mapping

  script:
  fasta_file = seq.name
  """
	#!/usr/bin/env python
	import annotations
	annotations.get_pdb_mapping("${fasta_file}", "${params.databases_dir}")
  """
}

process get_oma_mapping {

  // conda 'bioconda::biopython=1.68'

  publishDir 'annotation/oma_mapping/', mode: 'copy', overwrite: true

  when:
  params.oma == true

  input:
  file(seq) from merged_faa5


  output:
  file 'oma_mapping.tab' into oma_mapping
  file 'no_oma_mapping.faa' into no_oma_mapping

  script:
  fasta_file = seq.name
  """
#!/usr/bin/env python


from Bio import SeqIO
import sqlite3
from Bio.SeqUtils import CheckSum

conn = sqlite3.connect("${params.databases_dir}/oma/oma.db")
cursor = conn.cursor()

fasta_file = "${fasta_file}"

oma_map = open('oma_mapping.tab', 'w')
no_oma_mapping = open('no_oma_mapping.faa', 'w')

oma_map.write("locus_tag\\toma_id\\n")

records = SeqIO.parse(fasta_file, "fasta")
no_oma_mapping_records = []
for record in records:
    sql = 'select accession from hash_table where sequence_hash=?'
    cursor.execute(sql, (CheckSum.seguid(record.seq),))
    hits = cursor.fetchall()
    if len(hits) == 0:
        no_oma_mapping_records.append(record)
    else:
        for hit in hits:
          oma_map.write("%s\\t%s\\n" % (record.id,
                                              hit[0]))


SeqIO.write(no_oma_mapping_records, no_oma_mapping, "fasta")

  """
}

process execute_interproscan_no_uniparc_matches {

  publishDir 'annotation/interproscan', mode: 'copy', overwrite: true

  cpus 20
  memory '16 GB'
  // conda 'anaconda::openjdk=8.0.152'

  when:
  params.interproscan

  input:
  file(seq) from no_uniparc_mapping_faa.splitFasta( by: 300, file: "no_uniparc_match_chunk_" )

  output:
  file '*gff3' into interpro_gff3_no_uniparc
  file '*html.tar.gz' into interpro_html_no_uniparc
  file '*svg.tar.gz' into interpro_svg_no_uniparc
  file '*tsv' into interpro_tsv_no_uniparc
  file '*xml' into interpro_xml_no_uniparc
  file '*log' into interpro_log_no_uniparc

  script:
  n = seq.name
  """
  echo $INTERPRO_HOME/interproscan.sh --pathways --enable-tsv-residue-annot -f TSV,XML,GFF3,HTML,SVG -i ${n} -d . -T . --disable-precalc -cpu ${task.cpus}
  bash $INTERPRO_HOME/interproscan.sh --pathways --enable-tsv-residue-annot -f TSV,XML,GFF3,HTML,SVG -i ${n} -d . -T . --disable-precalc -cpu ${task.cpus} >> ${n}.log
  """
}


process execute_interproscan_uniparc_matches {

  publishDir 'annotation/interproscan', mode: 'copy', overwrite: true

  cpus	20
  memory '8 GB'
  // conda 'anaconda::openjdk=8.0.152'

  when:
  params.interproscan

  input:
  file(seq) from uniparc_mapping_faa.splitFasta( by: 1000, file: "uniparc_match_chunk_" )

  output:
  file '*gff3' into interpro_gff3_uniparc
  file '*html.tar.gz' into interpro_html_uniparc
  file '*svg.tar.gz' into interpro_svg_uniparc
  file '*tsv' into interpro_tsv_uniparc
  file '*xml' into interpro_xml_uniparc
  file '*log' into interpro_log_uniparc

  script:
  n = seq.name
  """
  echo $INTERPRO_HOME/interproscan.sh --pathways --enable-tsv-residue-annot -f TSV,XML,GFF3,HTML,SVG -i ${n} -d . -T . -iprlookup -cpu ${task.cpus}
  bash $INTERPRO_HOME/interproscan.sh --pathways --enable-tsv-residue-annot -f TSV,XML,GFF3,HTML,SVG -i ${n} -d . -T . -iprlookup -cpu ${task.cpus} >> ${n}.log
  """
}


process execute_kofamscan {

  publishDir 'annotation/KO', mode: 'copy', overwrite: true

  // conda 'hmmer=3.2.1 parallel ruby=2.4.5'

  cpus 4
  memory '8 GB'

  when:
  params.ko == true

  input:
  file(seq) from faa_chunks7

  output:
  file '*tab'

  script:
  n = seq.name

  // Hack for now
  """
  ${params.databases_dir}/kegg/exec_annotation ${n} -p ${params.databases_dir}/kegg/profiles/prokaryote.hal -k ${params.databases_dir}/kegg/ko_list --cpu ${task.cpus} -o ${n}.tab
  """
}


process execute_PRIAM {

  publishDir 'annotation/KO', mode: 'copy', overwrite: true

  container 'metagenlab/chlamdb_annotation:1.0.3'

  cpus 2
  memory '4 GB'

  when:
  params.PRIAM == true

  input:
  file(seq) from faa_chunks8

  output:
  file 'results/PRIAM_*/ANNOTATION/sequenceECs.txt' into PRIAM_results

  script:
  n = seq.name
  """
  conda activate /opt/conda/envs/priam
  java -jar  /usr/local/bin/PRIAM/PRIAM_search.jar -i ${n} -o results -p $params.databases_dir/PRIAM/PRIAM_JAN18 --num_proc ${task.cpus}
  """
}


PRIAM_results.collectFile(name: 'annotation/PRIAM/sequenceECs.txt')


process setup_orthology_db {
  /*
  - [ ] load locus_tag2hash table
  - [ ] load locus2orthogroup data into sqlite db (locus2orthogroup)
  */

  // conda 'biopython=1.73=py36h7b6447c_0'
  publishDir 'orthology/', mode: 'link', overwrite: true

  cpus 4
  memory '8 GB'

  when:
  params.refseq_diamond_BBH_phylogeny

  input:
  file nr_mapping_file from nr_mapping
  file orthogroup from orthogroups_2
  file nr_fasta from merged_faa6

  output:
  file 'orthology.db' into orthology_db

  script:
  """
  #!/usr/bin/env python

  import annotations
  annotations.setup_orthology_db("${nr_fasta}", "${nr_mapping_file}", "${orthogroup}")
  """
}


process setup_diamond_refseq_db {
  /*
  - [ ] load blast results into sqlite db
  */

  // conda 'bioconda::biopython=1.68 anaconda::pandas=0.23.4'
  publishDir 'annotation/diamond_refseq', mode: 'copy', overwrite: true
  echo false
  cpus 4
  memory '8 GB'

  when:
  params.refseq_diamond_BBH_phylogeny == true

  input:
  file diamond_tsv_list from refseq_diamond_results_sqlitedb.collect()

  output:
  file 'diamond_refseq.db' into diamond_refseq_db
  file 'nr_refseq_hits.tab' into refseq_diamond_nr

  script:
  """
	#!/usr/bin/env python
	import annotations
	annotations.setup_diamond_refseq_db("$diamond_tsv_list")
  """
}


process get_refseq_hits_taxonomy {

  // conda 'biopython=1.73=py36h7b6447c_0'

  publishDir 'annotation/diamond_refseq/', mode: 'copy', overwrite: true

  echo true

  when:
  params.diamond_refseq_taxonomy

  input:
  file refseq_hit_table from refseq_diamond_nr

  output:
  file 'refseq_taxonomy.db' into refseq_hit_taxid_mapping_db

  script:

  """
	#!/usr/bin/env python

	import annotations
	annotations.get_refseq_hits_taxonomy("$refseq_hit_table", "$params.databases_dir")
  """
}


process get_diamond_refseq_top_hits {
  /*
  - [ ] load blast results into sqlite db
  */

  // conda 'bioconda::biopython=1.68 anaconda::pandas=0.23.4'
  publishDir 'annotation/diamond_refseq_BBH_phylogenies', mode: 'copy', overwrite: true
  echo false
  cpus 4
  memory '8 GB'

  when:
  params.refseq_diamond_BBH_phylogeny

  input:
  file 'orthology.db' from orthology_db
  file 'refseq_taxonomy.db' from refseq_hit_taxid_mapping_db
  file 'diamond_refseq.db' from diamond_refseq_db

  output:
  file '*_nr_hits.faa' optional true into diamond_refseq_hits_fasta

  script:
  """
	#!/usr/bin/env python
	import annotations
	annotations.get_diamond_refseq_top_hits("$params.databases_dir",
	$params.refseq_diamond_BBH_phylogeny_phylum_filter,
	$params.refseq_diamond_BBH_phylogeny_top_n_hits)
  """
}

process align_refseq_BBH_with_mafft {

  conda 'bioconda::mafft=7.407'

  publishDir 'orthology/orthogroups_refseq_diamond_BBH_alignments', mode: 'copy', overwrite: true

  when:
  params.refseq_diamond_BBH_phylogeny == true

  input:
  file og from diamond_refseq_hits_fasta.flatten().collate( 20 )

  output:
  file "*_mafft.faa" into mafft_alignments_refseq_BBH

  script:
  """
  unset MAFFT_BINARIES
  for faa in ${og}; do
  mafft --anysymbol \$faa > \${faa/.faa/_mafft.faa}
  done
  """
}

mafft_alignments_refseq_BBH.flatten().set{ diamond_BBH_alignments }

process orthogroup_refseq_BBH_phylogeny_with_fasttree {

  conda 'bioconda::fasttree=2.1.10'
  cpus 4
  publishDir 'orthology/orthogroups_refseq_diamond_BBH_phylogenies', mode: 'copy', overwrite: true

  when:
  params.refseq_diamond_BBH_phylogeny == true

  input:
  each file(og) from diamond_BBH_alignments

  output:
    file "${og.baseName}.nwk"

  script:
  """
  FastTree ${og} > ${og.baseName}.nwk
  """
}


// Filter out small sequences and ambiguous AA
process filter_sequences {
  // conda 'biopython=1.73'

  publishDir 'data/', mode: 'copy', overwrite: true

  when:
  params.effector_prediction

  input: 
    file nr_fasta from merged_faa7

  output:
    file "filtered_sequences.faa" into filtered_sequences
  
  script:
	"""
	#!/usr/bin/env python
	import annotations
	annotations.filter_sequences("${nr_fasta}")
	"""
}

filtered_sequences.splitFasta( by: 5000, file: "chunk_" ).into{ nr_faa_large_sequences_chunks1
                                                                    nr_faa_large_sequences_chunks2
                                                                    nr_faa_large_sequences_chunks3
                                                                    nr_faa_large_sequences_chunks4 }

process execute_BPBAac {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  when:
  params.effector_prediction == true

  input:
  file "nr_fasta.faa" from nr_faa_large_sequences_chunks1

  output:
  file 'BPBAac_results.csv' into BPBAac_results

  script:
  """
  ln -s /usr/local/bin/BPBAac/BPBAacPre.R
  ln -s /usr/local/bin/BPBAac/BPBAac.Rdata
  ln -s /usr/local/bin/BPBAac/Classify.pl
  ln -s /usr/local/bin/BPBAac/DataPrepare.pl
  ln -s /usr/local/bin/BPBAac/Feature100.pl
  ln -s /usr/local/bin/BPBAac/Integ.pl
  ln -s /usr/local/bin/BPBAac/Neg100AacFrequency
  ln -s /usr/local/bin/BPBAac/Pos100AacFrequency
  sed 's/CRC-/CRC/g' nr_fasta.faa > edited_fasta.faa
  perl DataPrepare.pl edited_fasta.faa;
  Rscript BPBAacPre.R;
  sed -i 's/CRC/CRC-/g' FinalResult.csv;
  mv FinalResult.csv BPBAac_results.csv;
  """
}

BPBAac_results.collectFile(name: 'annotation/T3SS_effectors/BPBAac_results.tab')

process execute_effectiveT3 {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  when:
  params.effector_prediction == true

  input:
  file "nr_fasta.faa" from nr_faa_large_sequences_chunks2

  output:
  file 'effective_t3.out' into effectiveT3_results

  script:
  """
  ln -s /usr/local/bin/effective/module
  java -jar /usr/local/bin/effective/TTSS_GUI-1.0.1.jar -f nr_fasta.faa -m TTSS_STD-2.0.2.jar -t cutoff=0.9999 -o effective_t3.out -q
  """
}

effectiveT3_results.collectFile(name: 'annotation/T3SS_effectors/effectiveT3_results.tab')

process execute_DeepT3 {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  when:
  params.effector_prediction == true && false

  input:
  file "nr_fasta.faa" from nr_faa_large_sequences_chunks3

  output:
  file 'DeepT3_results.tab' into DeepT3_results

  script:
  """
  DeepT3_scores.py -f nr_fasta.faa -o DeepT3_results.tab -d /usr/local/bin/DeepT3/DeepT3/DeepT3-Keras/
  """
}

DeepT3_results.collectFile(name: 'annotation/T3SS_effectors/DeepT3_results.tab')

process execute_T3_MM {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  when:
  params.effector_prediction == true

  input:
  file "nr_fasta.faa" from nr_faa_large_sequences_chunks4

  output:
  file 'T3_MM_results.csv' into T3_MM_results

  script:
  """
  ln -s /usr/local/bin/T3_MM/log.freq.ratio.txt
  perl /usr/local/bin/T3_MM/T3_MM.pl nr_fasta.faa
  mv final.result.csv T3_MM_results.csv
  """
}


T3_MM_results.collectFile(name: 'annotation/T3SS_effectors/T3_MM_results.tab')


process execute_macsyfinder_T3SS {

  container 'metagenlab/chlamdb_annotation:1.0.3'

  publishDir 'annotation/macsyfinder/T3SS/', mode: 'copy', overwrite: true

  when:
  params.macsyfinder == true

  input:
  file(genome) from faa_genomes6

  output:
  file "macsyfinder-${genome.baseName}/macsyfinder.conf"
  file "macsyfinder-${genome.baseName}/macsyfinder.log"
  file "macsyfinder-${genome.baseName}/macsyfinder.out"
  file "macsyfinder-${genome.baseName}/macsyfinder.report"
  file "macsyfinder-${genome.baseName}/macsyfinder.summary"

  script:
  """
  python /usr/local/bin/macsyfinder/bin/macsyfinder --db-type unordered_replicon --sequence-db ${genome} -d /usr/local/bin/annotation_pipeline_nextflow/data/macsyfinder/secretion_systems/TXSS/definitions -p /usr/local/bin/annotation_pipeline_nextflow/data/macsyfinder/secretion_systems/TXSS/profiles all --coverage-profile 0.2 --i-evalue-select 1 --e-value-search 1
  mv macsyfinder-* macsyfinder-${genome.baseName}
  """
}


process execute_psortb {

  container 'metagenlab/psort:3.0.6'

  publishDir 'annotation/psortb/', mode: 'copy', overwrite: true

  when:
  params.psortb == true

  input:
  file(chunk) from faa_chunks9

  output:
  file "psortb_${chunk}.txt" into psortb_results

  script:
  """
  /usr/local/psortb/bin/psort --negative ${chunk} > psortb_${chunk}.txt
  """
}


process blast_pdb {

  // conda 'bioconda::blast=2.7.1'

  publishDir 'annotation/pdb_mapping', mode: 'copy', overwrite: true

  cpus 4

  when:
  params.pdb == true

  input:
  file(seq) from no_pdb_mapping.splitFasta( by: 1000, file: "chunk_" )

  output:
  file '*tab' into pdb_blast

  script:

  n = seq.name
  """
  blastp -db $params.databases_dir/pdb/pdb_seqres.faa -query ${n} -outfmt 6 -evalue 0.001  -num_threads ${task.cpus} > ${n}.tab
  """
}


process get_uniparc_crossreferences {

  publishDir 'annotation/uniparc_mapping/', mode: 'copy', overwrite: true

  when:
  params.uniparc == true

  input:
  file(table) from uniparc_mapping_tab1

  output:
  file 'uniparc_crossreferences.tab'

  script:

  """
#!/usr/bin/env python3.6
import sqlite3
import datetime
import logging

logging.basicConfig(filename='uniparc_crossrefs.log',level=logging.DEBUG)


conn = sqlite3.connect("${params.databases_dir}/uniprot/uniparc/uniparc.db")
cursor = conn.cursor()

o = open("uniparc_crossreferences.tab", "w")

sql = 'select db_name,accession, status from uniparc_cross_references t1 inner join crossref_databases t2 on t1.db_id=t2.db_id where uniparc_id=? and db_name not in ("SEED", "PATRIC", "EPO", "JPO", "KIPO", "USPTO");'

with open("${table}", 'r') as f:
    for n, row in enumerate(f):
        if n == 0:
            continue
        data = row.rstrip().split("\t")
        uniparc_id = str(data[1])
        checksum = data[0]
        cursor.execute(sql, [uniparc_id])
        crossref_list = cursor.fetchall()
        for crossref in crossref_list:
            db_name = crossref[0]
            db_accession = crossref[1]
            entry_status = crossref[2]
            o.write("%s\\t%s\\t%s\\t%s\\n" % ( checksum,
                                          db_name,
                                          db_accession,
                                          entry_status))

    """
}


process get_idmapping_crossreferences {

  publishDir 'annotation/uniparc_mapping/', mode: 'copy', overwrite: true
  echo true

  when:
  params.uniprot_idmapping

  input:
  file(table) from uniparc_mapping_tab2

  output:
  file 'idmapping_crossreferences.tab'

  script:

  """
#!/usr/bin/env python3.6
import sqlite3
import datetime
import logging

logging.basicConfig(filename='uniparc_crossrefs.log',level=logging.DEBUG)


conn = sqlite3.connect("${params.databases_dir}/uniprot/idmapping/idmapping.db")
cursor = conn.cursor()

o = open("idmapping_crossreferences.tab", "w")

sql = 'select uniprokb_accession, db_name,accession from uniparc2uniprotkb t1 inner join uniprotkb_cross_references t2 on t1.uniprotkb_id=t2.uniprotkb_id inner join database t3 on t2.db_id=t3.db_id where uniparc_accession=?;'

with open("${table}", 'r') as f:
    for n, row in enumerate(f):
        if n == 0:
            continue
        data = row.rstrip().split("\t")
        uniparc_accession = data[2]
        checksum = data[0]
        cursor.execute(sql, [uniparc_accession])
        crossref_list = cursor.fetchall()
        for crossref in crossref_list:
            uniprot_accession = crossref[0]
            db_name = crossref[1]
            db_accession = crossref[2]
            o.write("%s\\t%s\\t%s\\t%s\\n" % ( checksum,
                                               uniprot_accession,
                                               db_name,
                                               db_accession))

    """
}


process get_uniprot_goa_mapping {

  publishDir 'annotation/goa/', mode: 'copy', overwrite: true
  echo true

  when:
  params.uniprot_goa

  input:
  val (uniprot_acc_list) from uniprot_nr_accessions.collect()

  output:
  file 'goa_uniprot_exact_annotations.tab'

  script:

  """
	#!/usr/bin/env python
	import annotations
	annotations.get_uniprot_goa_mapping("$params.databases_dir", $uniprot_acc_list)
  """
}


workflow.onComplete {
  // Display complete message
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  mail = [ to: 'trestan.pillonel@gmail.com',
           subject: 'Annotation Pipeline - DONE',
           body: 'SUCCESS!' ]
}

workflow.onError {
  // Display error message
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}
