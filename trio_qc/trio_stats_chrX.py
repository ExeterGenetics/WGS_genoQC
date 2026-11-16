import pandas as pd
from cyvcf2 import VCF
import numpy as np
from tqdm import tqdm
import sys

input_vcf=sys.argv[1]
output=sys.argv[2]

x=VCF(input_vcf, gts012=True)

trios=pd.read_csv(sys.argv[3], sep=' ', header=None)
trios=trios[(trios[1].astype('str').isin(x.samples)) & (trios[2].astype('str').isin(x.samples)) & (trios[3].astype('str').isin(x.samples))]
trios[1]=trios[1].astype('str')
trios[2]=trios[2].astype('str')
trios[3]=trios[3].astype('str')
trios['Ngenos']=0
trios['Ntransmitted']=0
trios['Nuntransmitted']=0
girl_trios=trios[trios[4]==2]
boy_trios=trios[trios[4]==1]

x1=pd.Series(x.samples)
boy_mums=x1[x1.isin(boy_trios[3])].index.tolist()
boy_dads=x1[x1.isin(boy_trios[2])].index.tolist()

girl_dads=x1[x1.isin(girl_trios[2])].index.tolist()
girl_mums=x1[x1.isin(girl_trios[3])].index.tolist()

samples=np.array(x.samples)
all_mums=sorted(set(boy_mums) | set(girl_mums))  # each mother once, also when she has both a son and a daughter proband
mum_of=dict(zip(trios[1], trios[3]))             # proband -> mother

for variant in tqdm(x):
    if (variant.FILTERS[0]=='PASS') and (variant.INFO.get('BCSQ')==None):
        if (sys.argv[4] == 'indel') | (sys.argv[4] == 'Indel') | (sys.argv[4] == 'INDEL'):
            indel = True
        else:
            indel = False

        if variant.is_indel == indel:
            # singleton: exactly one heterozygous mother and no homozygous-alt mother, among all trio mothers
            mum_gts=variant.gt_types[all_mums]
            het_mums=set(samples[all_mums][mum_gts==1])
            # a heterozygous mother who is the proband of another heterozygous mother inherited the allele,
            # so she does not count as a second carrier
            carriers=[m for m in het_mums if mum_of.get(m) not in het_mums]
            singleton=(len(carriers)==1) and not (mum_gts==2).any()
            if singleton:
                tmp_trio=boy_trios[boy_trios[3].isin(carriers)]
                for i in range(tmp_trio.shape[0]):
                    proband=tmp_trio.iloc[i,1]
                    mother=tmp_trio.iloc[i,3]
                    proband_geno=variant.gt_types[x.samples.index(proband)]
                    mother_geno=variant.gt_types[x.samples.index(mother)]
                    if proband_geno!=3:
                        trios.loc[trios[1]==proband, 'Ngenos']+=1
                        if proband_geno==0:
                            trios.loc[trios[1]==proband, 'Nuntransmitted']+=1
                        elif proband_geno==2:
                            trios.loc[trios[1]==proband, 'Ntransmitted']+=1

            if singleton:
                tmp_trio=girl_trios[girl_trios[3].isin(carriers)]

                for i in range(tmp_trio.shape[0]):
                    proband=tmp_trio.iloc[i,1]
                    father=tmp_trio.iloc[i,2]
                    mother=tmp_trio.iloc[i,3]
                    proband_geno=variant.gt_types[x.samples.index(proband)]
                    mother_geno=variant.gt_types[x.samples.index(mother)]
                    father_geno=variant.gt_types[x.samples.index(father)]
                    
                    if proband_geno!=3:
                        if proband_geno==0:
                            trios.loc[trios[1]==proband, 'Nuntransmitted']+=1
                            trios.loc[trios[1]==proband, 'Ngenos']+=1
                        elif proband_geno==1 and father_geno==0:
                            trios.loc[trios[1]==proband, 'Ntransmitted']+=1
                            trios.loc[trios[1]==proband, 'Ngenos']+=1
                        elif proband_geno==2:
                            trios.loc[trios[1]==proband, 'Ntransmitted']+=1
                            trios.loc[trios[1]==proband, 'Ngenos']+=1
trios.to_csv(output, index=False)

