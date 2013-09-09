MODULE FIRE
 
! Compute combustion
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
   
CHARACTER(255), PARAMETER :: fireid='$Id$'
CHARACTER(255), PARAMETER :: firerev='$Revision$'
CHARACTER(255), PARAMETER :: firedate='$Date$'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER

PUBLIC COMBUSTION, GET_REV_fire

CONTAINS
 
SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver

CALL COMBUSTION_GENERAL

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL

! Generic combustion routine for multi-step reactions

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_DIFF,GET_SENSIBLE_ENTHALPY
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW,N
REAL(EB):: ZZ_GET(0:N_TRACKED_SPECIES),ZZ_MIN=1.E-10_EB,DZZ(0:N_TRACKED_SPECIES),CP,HDIFF
LOGICAL :: DO_REACTION,REACTANTS_PRESENT,Q_EXISTS
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM,SM0

Q          = 0._EB
D_REACTION = 0._EB
Q_EXISTS = .FALSE.
SM0 => SPECIES_MIXTURE(0)

!$OMP PARALLEL DEFAULT(NONE) &
!$OMP SHARED(KBAR,JBAR,IBAR,SOLID,CELL_INDEX,N_TRACKED_SPECIES,N_REACTIONS,REACTION,COMBUSTION_ODE,Q,RSUM,TMP,PBAR, &
!$OMP        PRESSURE_ZONE,RHO,ZZ,D_REACTION,SPECIES_MIXTURE,SM0,DT,CONSTANT_SPECIFIC_HEAT)

!$OMP DO SCHEDULE(STATIC) COLLAPSE(3)&
!$OMP PRIVATE(K,J,I,ZZ_GET,DO_REACTION,NR,RN,REACTANTS_PRESENT,ZZ_MIN,Q_EXISTS,SM,CP,HDIFF,DZZ)

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         !Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         ZZ_GET(0) = 1._EB - MIN(1._EB,SUM(ZZ_GET(1:N_TRACKED_SPECIES)))
         DO_REACTION = .FALSE.
         REACTION_LOOP: DO NR=1,N_REACTIONS
            RN=>REACTION(NR)
            REACTANTS_PRESENT = .TRUE.
               DO NS=0,N_TRACKED_SPECIES
                  IF (RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN) THEN
                     REACTANTS_PRESENT = .FALSE.
                     EXIT
                  ENDIF
               END DO
             DO_REACTION = REACTANTS_PRESENT
             IF (DO_REACTION) EXIT REACTION_LOOP
         END DO REACTION_LOOP
         IF (.NOT. DO_REACTION) CYCLE ILOOP
         DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) ! store old ZZ for divergence term
         ! Call combustion integration routine
         CALL COMBUSTION_MODEL(I,J,K,ZZ_GET,Q(I,J,K))
         ! Update RSUM and ZZ
         Q_IF: IF (ABS(Q(I,J,K)) > TWO_EPSILON_EB) THEN
            Q_EXISTS = .TRUE.
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 
            TMP(I,J,K) = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHO(I,J,K))
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES)
            CP_IF: IF (.NOT.CONSTANT_SPECIFIC_HEAT) THEN
               ! Divergence term
               DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) - DZZ(1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
               DO N=1,N_TRACKED_SPECIES
                  SM => SPECIES_MIXTURE(N)
                  CALL GET_SENSIBLE_ENTHALPY_DIFF(N,TMP(I,J,K),HDIFF)
                  D_REACTION(I,J,K) = D_REACTION(I,J,K) + ( (SM%RCON-SM0%RCON)/RSUM(I,J,K) - HDIFF/(CP*TMP(I,J,K)) )*DZZ(N)/DT
               ENDDO
            ENDIF CP_IF
         ENDIF Q_IF
      ENDDO ILOOP
   ENDDO
ENDDO
!$OMP END DO
!$OMP END PARALLEL

IF (.NOT. Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.

DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (WALL(IW)%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY .AND. WALL(IW)%BOUNDARY_TYPE/=OPEN_BOUNDARY) CYCLE
   II  = WALL(IW)%ONE_D%II
   JJ  = WALL(IW)%ONE_D%JJ
   KK  = WALL(IW)%ONE_D%KK
   IIG = WALL(IW)%ONE_D%IIG
   JJG = WALL(IW)%ONE_D%JJG
   KKG = WALL(IW)%ONE_D%KKG
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO

END SUBROUTINE COMBUSTION_GENERAL
   
SUBROUTINE COMBUSTION_MODEL(I,J,K,ZZ_GET,Q_OUT)
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE PHYSICAL_FUNCTIONS, ONLY: LES_FILTER_WIDTH_FUNCTION, GET_AVERAGE_SPECIFIC_HEAT,GET_SPECIFIC_GAS_CONSTANT
USE RADCONS, ONLY: RADIATIVE_FRACTION
INTEGER,INTENT(IN):: I,J,K
REAL(EB),INTENT(OUT):: Q_OUT
REAL(EB),INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),DZZDT1_1(0:N_TRACKED_SPECIES),DZZDT1_2(0:N_TRACKED_SPECIES),DZZDT2_1(0:N_TRACKED_SPECIES), &
            DZZDT2_2(0:N_TRACKED_SPECIES),DZZDT4_1(0:N_TRACKED_SPECIES),DZZDT4_2(0:N_TRACKED_SPECIES),RATE_CONSTANT(1:N_REACTIONS),&
            RATE_CONSTANT2(1:N_REACTIONS),ERR_EST,ERR_TOL,ZZ_TEMP(0:N_TRACKED_SPECIES),TMP_0,TMP_1,TMP_2,TMP_4,&
            A1(0:N_TRACKED_SPECIES),A2(0:N_TRACKED_SPECIES),A4(0:N_TRACKED_SPECIES),Q_SUM,Q_CALC,&
            DT_SUB,DT_SUB_NEW,DT_ITER,ZZ_STORE(0:N_TRACKED_SPECIES,0:3),TV(0:2,0:N_TRACKED_SPECIES),CELL_VOLUME,CELL_MASS,&
            ZZ_DIFF(0:2,0:N_TRACKED_SPECIES),ZZ_MIXED(0:N_TRACKED_SPECIES),ZZ_GET_0(0:N_TRACKED_SPECIES),ZETA0,ZETA,ZETA1,&
            DZZDT(0:N_TRACKED_SPECIES),SMIX_MIX_MASS_0(0:N_TRACKED_SPECIES),SMIX_MIX_MASS(0:N_TRACKED_SPECIES),TOTAL_MIX_MASS,&
            TAU_D,TAU_G,TAU_U,DELTA,CP_BAR_0,CP_BAR_U,CP_BAR_M,TMP_MIXED_ZONE,ZZ_CHECK(0:N_TRACKED_SPECIES)
REAL(EB), PARAMETER :: DT_SUB_MIN=1.E-10_EB,ZZ_MIN=1.E-10_EB
INTEGER :: NR,NS,NSS,ITER,TVI,RICH_ITER,TIME_ITER,TIME_ITER_MAX,SR
INTEGER, PARAMETER :: SUB_DT1=1,SUB_DT2=2,SUB_DT4=4,TV_ITER_MIN=5,RICH_ITER_MAX=5
LOGICAL :: EXTINCT(1:N_REACTIONS),TV_FLUCT(0:N_TRACKED_SPECIES)
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

TIME_ITER_MAX= HUGE(0)

IF (FIXED_MIX_TIME>0._EB) THEN
   MIX_TIME(I,J,K)=FIXED_MIX_TIME
ELSE
   DELTA = LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K))
   TAU_D=0._EB
   DO NR =1,N_REACTIONS
      RN => REACTION(NR)
      TAU_D = MAX(TAU_D,D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX))
   ENDDO
   TAU_D = DELTA**2/TAU_D
   IF (LES) THEN
      TAU_U = C_DEARDORFF*SC*RHO(I,J,K)*DELTA**2/MU(I,J,K) ! turbulent mixing time scale, tau_u=delta/sqrt(ksgs)
      TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB)) ! acceleration time scale
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! Eq. 7, McDermott, McGrattan, Floyd
   ELSE
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,TAU_D)
   ENDIF
ENDIF

ZZ_STORE(:,:) = 0._EB
Q_OUT = 0._EB
Q_CALC = 0._EB
Q_SUM = 0._EB
ITER= 0
DT_ITER = 0._EB
DT_SUB = DT 
DT_SUB_NEW = DT
ERR_TOL = RICHARDSON_ERROR_TOLERANCE
EXTINCT(:) = .FALSE.
ZZ_GET_0 = ZZ_GET
ZZ_TEMP = ZZ_GET
ZZ_MIXED = ZZ_GET
ZETA0 = INITIAL_UNMIXED_FRACTION
ZETA  = ZETA0
ZETA1 = ZETA0
CELL_VOLUME = DX(I)*DY(J)*DZ(K)
CELL_MASS = RHO(I,J,K)*CELL_VOLUME
TOTAL_MIX_MASS = (1._EB-ZETA0)*CELL_MASS
SMIX_MIX_MASS_0 = ZZ_GET*TOTAL_MIX_MASS
SMIX_MIX_MASS = SMIX_MIX_MASS_0
IF (TEMPERATURE_DEPENDENT_REACTION) THEN
   TMP_MIXED_ZONE = TMP(I,J,K) !(1._EB-ZETA0)*MAX(TMP_FLAME(I,J,K),TMP(I,J,K))+ZETA0*TMP(I,J,K)
ELSE
   TMP_MIXED_ZONE = TMP(I,J,K)
ENDIF
CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_GET_0,CP_BAR_U,TMP(I,J,K))
   
INTEGRATION_LOOP: DO TIME_ITER = 1,TIME_ITER_MAX
   ZETA1 = ZETA0*EXP(-(DT_ITER+DT_SUB)/MIX_TIME(I,J,K))
   SMIX_MIX_MASS = MAX(0._EB,SMIX_MIX_MASS_0 + (ZETA-ZETA1)*CELL_MASS*ZZ_GET_0)
   TOTAL_MIX_MASS = SUM(SMIX_MIX_MASS)
   ZZ_MIXED = SMIX_MIX_MASS/(TOTAL_MIX_MASS)
   IF (TEMPERATURE_DEPENDENT_REACTION) THEN
      CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_MIXED,CP_BAR_0,TMP_MIXED_ZONE)
      CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_TEMP,CP_BAR_M,TMP_MIXED_ZONE)   
      TMP_MIXED_ZONE = ((ZETA-ZETA1)*CELL_MASS*TMP(I,J,K)*CP_BAR_U+SUM(SMIX_MIX_MASS_0)*TMP_MIXED_ZONE*CP_BAR_0) &
         /(TOTAL_MIX_MASS*CP_BAR_M)
   ENDIF
   IF (SUPPRESSION .AND. TIME_ITER == 1) CALL EXTINCTION(ZZ_MIXED,TMP_MIXED_ZONE,EXTINCT) 
      RK2_IF: IF (COMBUSTION_ODE /= RK2_RICHARDSON) THEN ! Explicit Euler 
         DO SR=0,SERIES_REAC
            DZZDT1_1 = 0._EB
            ZZ_0 = ZZ_MIXED
            RATE_CONSTANT = 0._EB
            CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_0,I,J,K,DT_SUB,TMP_MIXED_ZONE,EXTINCT)
            REACTION_LOOP1: DO NR = 1, N_REACTIONS
               RN => REACTION(NR)
               DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
               ZZ_CHECK = ZZ_0 + (DZZDT1_1+DZZDT)*DT_SUB
               IF (ANY(ZZ_CHECK < 0._EB)) THEN
                  DO NSS=0,N_TRACKED_SPECIES
                     IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                        RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),ZZ_0(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB))
                     ENDIF
                  ENDDO
                  DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
               ENDIF
               DZZDT1_1 = DZZDT1_1+DZZDT
            ENDDO REACTION_LOOP1
            A1 = ZZ_0 + DZZDT1_1*DT_SUB
            ZZ_MIXED = A1
         ENDDO 
         IF (TIME_ITER > 1) CALL SHUTDOWN('ERROR: Error in Simple Chemistry')
         IF (ALL(DZZDT1_1 < 0._EB)) EXIT INTEGRATION_LOOP
      ELSE RK2_IF ! RK2 w/ Richardson
         ERR_EST = MAX(10._EB,10._EB*ERR_TOL)
         RICH_EX_LOOP: DO RICH_ITER =1,RICH_ITER_MAX
            DT_SUB = DT_SUB_NEW
            IF (DT_ITER + DT_SUB > DT) THEN
               DT_SUB = DT - DT_ITER
            ENDIF
            !--------------------
            ! Calculate A1 term
            ! Time step = DT_SUB
            !--------------------
            ZZ_0 = ZZ_MIXED
            TMP_0 = TMP_MIXED_ZONE
            TMP_1 = TMP_MIXED_ZONE
            ODE_LOOP1: DO NS = 1,SUB_DT1
               DO SR=0,SERIES_REAC
                  DZZDT1_1 = 0._EB
                  RATE_CONSTANT = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_0,I,J,K,DT_SUB,TMP_0,EXTINCT)
                  REACTION_LOOP1_1: DO NR = 1,N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT. RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ZZ_CHECK = ZZ_0 + (DZZDT1_1+DZZDT)*DT_SUB
                     IF (ANY( ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),ZZ_0(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ENDIF
                     DZZDT1_1 = DZZDT1_1+DZZDT
                  ENDDO REACTION_LOOP1_1
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_0,CP_BAR_0,TMP_0)
                     TMP_1 = TMP_0 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT1_1*DT_SUB)/CP_BAR_0
                  ENDIF
                  A1 = ZZ_0 + DZZDT1_1*DT_SUB
                  IF (ALL(REACTION(:)%FAST_CHEMISTRY) .AND. SR == SERIES_REAC) THEN ! All fast reactions solve explicit Euler
                     A4 = A1
                     A2 = A1
                     TMP_4 = TMP_1
                     TMP_2 = TMP_1
                     DT_SUB = DT - DT_ITER 
                     EXIT RICH_EX_LOOP
                  ENDIF
                  DZZDT1_2 = 0._EB
                  RATE_CONSTANT2 = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT2,A1,I,J,K,DT_SUB,TMP_1,EXTINCT)
                  REACTION_LOOP1_2: DO NR = 1, N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT.RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ZZ_CHECK = A1 + (DZZDT1_2+DZZDT)*DT_SUB
                     IF (ANY( ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT2(NR) = MIN(RATE_CONSTANT2(NR),A1(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ENDIF
                     DZZDT1_2 = DZZDT1_2+DZZDT
                  ENDDO REACTION_LOOP1_2
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(A1,CP_BAR_0,TMP_1)
                     TMP_1 = TMP_1 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT1_2*DT_SUB)/CP_BAR_0
                     TMP_1 = 0.5_EB*(TMP_1 + TMP_0)
                     TMP_0 = TMP_1
                  ENDIF
                  A1 = A1 + DZZDT1_2*DT_SUB
                  A1 = 0.5_EB*(ZZ_0 + A1)
                  ZZ_0 = A1
               ENDDO
            ENDDO ODE_LOOP1
            !--------------------
            ! Calculate A2 term
            ! Time step = DT_SUB/2
            !--------------------
            ZZ_0 = ZZ_MIXED
            TMP_0 = TMP_MIXED_ZONE
            TMP_2 = TMP_MIXED_ZONE
            ODE_LOOP2: DO NS = 1,SUB_DT2
               DO SR=0,SERIES_REAC
                  DZZDT2_1 = 0._EB
                  RATE_CONSTANT = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_0,I,J,K,DT_SUB,TMP_0,EXTINCT)
                  REACTION_LOOP2_1: DO NR = 1,N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT.RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ZZ_CHECK = ZZ_0 + (DZZDT2_1+DZZDT)*(DT_SUB*0.5_EB)
                     IF (ANY( ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),ZZ_0(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB*0.5_EB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ENDIF
                     DZZDT2_1 = DZZDT2_1+DZZDT
                  ENDDO REACTION_LOOP2_1
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_0,CP_BAR_0,TMP_0)
                     TMP_2 = TMP_0 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT2_1*DT_SUB*0.5_EB)/CP_BAR_0
                  ENDIF
                  A2 = ZZ_0 + DZZDT2_1*(DT_SUB*0.5_EB)
                  DZZDT2_2 = 0._EB
                  RATE_CONSTANT2 = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT2,A2,I,J,K,DT_SUB,TMP_2,EXTINCT)
                  REACTION_LOOP2_2: DO NR = 1,N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT. RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ZZ_CHECK = A2 + (DZZDT2_2+DZZDT)*(DT_SUB*0.5_EB)
                     IF (ANY(ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT2(NR) = MIN(RATE_CONSTANT2(NR),A2(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB*0.5_EB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ENDIF
                     DZZDT2_2 = DZZDT2_2+DZZDT
                  ENDDO REACTION_LOOP2_2
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(A2,CP_BAR_0,TMP_2)
                     TMP_2 = TMP_2 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT2_2*DT_SUB*0.5_EB)/CP_BAR_0
                     TMP_2 = 0.5_EB*(TMP_2 + TMP_0)
                     TMP_0 = TMP_2
                  ENDIF
                  A2 = A2 + DZZDT2_2*(DT_SUB*0.5_EB)
                  A2 = 0.5_EB*(ZZ_0 + A2)
                  ZZ_0 = A2
               ENDDO
            ENDDO ODE_LOOP2
            !--------------------
            ! Calculate A4 term  
            ! Time step = DT_SUB/4
            !-------------------- 
            ZZ_0 = ZZ_MIXED
            TMP_0 = TMP_MIXED_ZONE
            TMP_4 = TMP_MIXED_ZONE
            ODE_LOOP4: DO NS = 1,SUB_DT4
               DO SR=0,SERIES_REAC
                  DZZDT4_1 = 0._EB
                  RATE_CONSTANT = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_0,I,J,K,DT_SUB,TMP_0,EXTINCT)
                  REACTION_LOOP4_1: DO NR = 1,N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT.RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ZZ_CHECK = ZZ_0 + (DZZDT4_1+DZZDT)*(DT_SUB*0.25_EB)
                     IF (ANY(ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),ZZ_0(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB*0.25_EB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
                     ENDIF
                     DZZDT4_1 = DZZDT4_1+DZZDT
                  END DO REACTION_LOOP4_1
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_0,CP_BAR_0,TMP_0)
                     TMP_4 = TMP_0 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT4_1*DT_SUB*0.25_EB)/CP_BAR_0
                  ENDIF
                  A4 = ZZ_0 + DZZDT4_1*(DT_SUB*0.25_EB)
                  DZZDT4_2 = 0._EB
                  RATE_CONSTANT2 = 0._EB
                  CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT2,A4,I,J,K,DT_SUB,TMP_4,EXTINCT)
                  REACTION_LOOP4_2: DO NR = 1,N_REACTIONS
                     RN => REACTION(NR)
                     IF (.NOT.RN%FAST_CHEMISTRY .AND. SR < SERIES_REAC) RATE_CONSTANT(NR) = 0._EB
                     DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ZZ_CHECK = A4 + (DZZDT4_2+DZZDT)*(DT_SUB*0.25_EB)
                     IF (ANY(ZZ_CHECK < 0._EB)) THEN
                        DO NSS=0,N_TRACKED_SPECIES
                           IF (ZZ_CHECK(NSS) < 0._EB .AND. ABS(DZZDT(NSS))>TWO_EPSILON_EB) THEN
                              RATE_CONSTANT2(NR) = MIN(RATE_CONSTANT2(NR),A4(NSS)/(ABS(RN%NU_MW_O_MW_F(NSS))*DT_SUB*0.25_EB))
                           ENDIF
                        ENDDO
                        DZZDT = RN%NU_MW_O_MW_F*RATE_CONSTANT2(NR)
                     ENDIF
                     DZZDT4_2 = DZZDT4_2+DZZDT
                  ENDDO REACTION_LOOP4_2
                  IF (TEMPERATURE_DEPENDENT_REACTION) THEN
                     CALL GET_AVERAGE_SPECIFIC_HEAT(A4,CP_BAR_0,TMP_4)
                     TMP_4 = TMP_4 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT4_2*DT_SUB*0.25_EB)/CP_BAR_0
                     TMP_4 = 0.5_EB*(TMP_4 + TMP_0)
                     TMP_0 = TMP_4
                  ENDIF
                  A4 = A4 + DZZDT4_2*(DT_SUB*0.25_EB)
                  A4 = 0.5_EB*(ZZ_0 + A4)
                  ZZ_0 = A4
               ENDDO
            ENDDO ODE_LOOP4
            ! Species Error Analysis
            ERR_EST = MAXVAL(ABS((4._EB*A4-5._EB*A2+A1)))/45._EB  ! Estimate Error
            DT_SUB_NEW = MIN(MAX(DT_SUB*(ERR_TOL/(ERR_EST+TWO_EPSILON_EB))**(0.25_EB),DT_SUB_MIN),DT-DT_ITER) ! New Time Step
            IF (RICH_ITER == RICH_ITER_MAX) EXIT RICH_EX_LOOP
            IF (ERR_EST <= ERR_TOL) EXIT RICH_EX_LOOP
            ZETA1 = ZETA0*EXP(-(DT_ITER+DT_SUB_NEW)/MIX_TIME(I,J,K))
            SMIX_MIX_MASS =  MAX(0._EB,SMIX_MIX_MASS_0 + (ZETA-ZETA1)*CELL_MASS*ZZ_GET_0)
            TOTAL_MIX_MASS = SUM(SMIX_MIX_MASS)
            ZZ_MIXED = SMIX_MIX_MASS/(TOTAL_MIX_MASS)
         ENDDO RICH_EX_LOOP
         ZZ_MIXED = (4._EB*A4-A2)*ONTH
         IF (TEMPERATURE_DEPENDENT_REACTION) TMP_MIXED_ZONE = (4._EB*TMP_4-TMP_2)*ONTH
      ENDIF RK2_IF 
   DT_ITER = DT_ITER + DT_SUB
   ITER = ITER + 1
   IF (OUTPUT_CHEM_IT) THEN
      CHEM_SUBIT(I,J,K) = ITER
   ENDIF
   ZZ_GET =  ZETA1*ZZ_GET_0 + (1._EB-ZETA1)*ZZ_MIXED ! Combine mixed and unmixed
   ! Heat Release
   Q_SUM = 0._EB
   IF (MAXVAL(ABS(ZZ_GET-ZZ_TEMP)) > ZZ_MIN) THEN
      Q_SUM = Q_SUM - RHO(I,J,K)*SUM(SPECIES_MIXTURE%H_F*(ZZ_GET-ZZ_TEMP))
   ENDIF
   IF (Q_CALC + Q_SUM > Q_UPPER*DT) THEN
      Q_OUT = Q_UPPER
      ZZ_GET = ZZ_TEMP + (Q_UPPER*DT/(Q_CALC + Q_SUM))*(ZZ_GET-ZZ_TEMP)
      EXIT INTEGRATION_LOOP
   ELSE
      Q_CALC = Q_CALC+Q_SUM
      Q_OUT = Q_CALC/DT
   ENDIF
   ! Temperature Dependence 
   IF (TEMPERATURE_DEPENDENT_REACTION) THEN
      IF (COMBUSTION_ODE /= RK2_RICHARDSON) THEN
         CALL GET_AVERAGE_SPECIFIC_HEAT(A1,CP_BAR_0,TMP_0)
         TMP_MIXED_ZONE = TMP_0 + (1._EB-RADIATIVE_FRACTION)*SUM(-SPECIES_MIXTURE%H_F*DZZDT1_1)/CP_BAR_0
      ENDIF
      TMP_FLAME(I,J,K) = TMP_MIXED_ZONE
   ENDIF
   ! Total Variation Scheme
   IF (N_REACTIONS > 1) THEN
      DO NS = 0,N_TRACKED_SPECIES
         DO TVI = 0,2
            ZZ_STORE(NS,TVI)=ZZ_STORE(NS,TVI+1)
         ENDDO
         ZZ_STORE(NS,3) = ZZ_GET(NS)
      ENDDO
      TV_FLUCT(:) = .FALSE.
      IF (ITER >= TV_ITER_MIN) THEN
         SPECIES_LOOP_TV: DO NS = 0,N_TRACKED_SPECIES
            DO TVI = 0,2
               TV(TVI,NS) = ABS(ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI))
               ZZ_DIFF(TVI,NS) = ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI)
            ENDDO
            IF (SUM(TV(:,NS)) < ERR_TOL .OR. SUM(TV(:,NS)) >= ABS(2.9_EB*SUM(ZZ_DIFF(:,NS)))) THEN
                  TV_FLUCT(NS) = .TRUE.
               ENDIF
            IF (ALL(TV_FLUCT)) EXIT INTEGRATION_LOOP
         ENDDO SPECIES_LOOP_TV
      ENDIF
   ENDIF
   ZZ_TEMP = ZZ_GET
   SMIX_MIX_MASS_0 = ZZ_MIXED*TOTAL_MIX_MASS
   ZETA = ZETA1
   IF (DT_ITER >= DT) EXIT INTEGRATION_LOOP
ENDDO INTEGRATION_LOOP
IF (REAC_SOURCE_CHECK) REAC_SOURCE_TERM(I,J,K,:) = (ZZ_GET_0-ZZ_GET)*CELL_MASS/DT

END SUBROUTINE COMBUSTION_MODEL


RECURSIVE SUBROUTINE EXTINCTION(ZZ_MIXED_IN,TMP_MIXED_ZONE,EXTINCT)
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
REAL(EB), INTENT(IN) :: ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
LOGICAL, INTENT(INOUT) :: EXTINCT(1:N_REACTIONS)
INTEGER :: NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

SELECT CASE (EXTINCT_MOD)
   CASE(EXTINCTION_1)
      EXTINCT(:) = .FALSE.
      DO NR = 1,N_REACTIONS
         RN => REACTION(NR)         
         IF (RN%FAST_CHEMISTRY) THEN
            IF(EXTINCT_1(ZZ_MIXED_IN,TMP_MIXED_ZONE,NR)) EXTINCT(NR) = .TRUE.
         ENDIF
      ENDDO
   CASE(EXTINCTION_2)
      EXTINCT(:) = .FALSE.
      IF (ANY(REACTION(:)%FAST_CHEMISTRY)) THEN
         IF(EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED_ZONE)) THEN
            DO NR = 1,N_REACTIONS
               RN => REACTION(NR)
               IF (RN%FAST_CHEMISTRY) EXTINCT(NR) = .TRUE.
            ENDDO   
         ENDIF
      ENDIF   
END SELECT

END SUBROUTINE EXTINCTION


LOGICAL FUNCTION EXTINCT_1(ZZ_IN,TMP_MIXED_ZONE,NR)
USE PHYSICAL_FUNCTIONS,ONLY:GET_AVERAGE_SPECIFIC_HEAT
REAL(EB),INTENT(IN)::ZZ_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
REAL(EB):: Y_O2,Y_O2_CRIT,CPBAR
INTEGER, INTENT(IN) :: NR
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()
RN => REACTION(NR)

EXTINCT_1 = .FALSE.
IF (TMP_MIXED_ZONE < RN%AUTO_IGNITION_TEMPERATURE) THEN
   EXTINCT_1 = .TRUE.
ELSE
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_IN,CPBAR,TMP_MIXED_ZONE)
   DO NS = 0,N_TRACKED_SPECIES
      IF (RN%NU(NS)<-TWO_EPSILON_EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
         Y_O2 = ZZ_IN(NS)
      ENDIF
   ENDDO
   Y_O2_CRIT = CPBAR*(RN%CRIT_FLAME_TMP-TMP_MIXED_ZONE)/RN%EPUMO2
   IF (Y_O2 < Y_O2_CRIT) EXTINCT_1 = .TRUE.
ENDIF

END FUNCTION EXTINCT_1


LOGICAL FUNCTION EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED_ZONE)
USE PHYSICAL_FUNCTIONS,ONLY:GET_SENSIBLE_ENTHALPY
REAL(EB),INTENT(IN)::ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
REAL(EB):: DZ_AIR,DZ_FUEL,DZ_NONFUEL,H_F_0,H_F_N,H_F_N_TEMP,H_G_0,H_G_N,H_G_N_TEMP,ZZ_EXTINCT(1:3),&
           F_A_EXTINCT,ZZ_FUEL_EXTINCT(0:N_TRACKED_SPECIES),ZZ_DIL_EXTINCT(0:N_TRACKED_SPECIES),HOC_EXTINCT,AIT_EXTINCT,&
           DZ_F(1:N_REACTIONS),DZ_FRAC_F(1:N_REACTIONS),FAST_COUNT,OX_COUNT(0:N_TRACKED_SPECIES),FUEL_COUNT(0:N_TRACKED_SPECIES)
INTEGER :: NS,NRR
TYPE(REACTION_TYPE),POINTER :: RNN=>NULL()

EXTINCT_2 = .FALSE.
ZZ_EXTINCT(:) = 0._EB
ZZ_FUEL_EXTINCT(:) = 0._EB
ZZ_DIL_EXTINCT = ZZ_MIXED_IN
DZ_F(:) = 0._EB
OX_COUNT(:) = 0._EB
FUEL_COUNT(:) = 0._EB
F_A_EXTINCT = 0._EB
HOC_EXTINCT = 0._EB
AIT_EXTINCT = 0._EB
FAST_COUNT = 0._EB

DO NRR = 1,N_REACTIONS
   RNN => REACTION(NRR)
   IF (RNN%FAST_CHEMISTRY .AND. RNN%HEAT_OF_COMBUSTION > 0._EB) THEN
      DZ_F(NRR) = 1.E10_EB
      FAST_COUNT = FAST_COUNT + 1._EB
      DO NS = 0,N_TRACKED_SPECIES
         IF (RNN%NU(NS) < 0._EB) THEN
            DZ_F(NRR) = MIN(DZ_F(NRR),-ZZ_MIXED_IN(NS)/RNN%NU_MW_O_MW_F(NS))
            IF (NS == RNN%FUEL_SMIX_INDEX) THEN
               IF (FUEL_COUNT(NS) < 1._EB) THEN
                  ZZ_EXTINCT(1) = ZZ_EXTINCT(1) + ZZ_MIXED_IN(NS) ! lumped fuel for all reactions
                  ZZ_FUEL_EXTINCT(NS) = ZZ_MIXED_IN(NS)
                  ZZ_DIL_EXTINCT(NS) = ZZ_DIL_EXTINCT(NS) - ZZ_MIXED_IN(NS)
               ENDIF
               FUEL_COUNT(NS) = FUEL_COUNT(NS) + 1._EB
            ELSE
               IF (OX_COUNT(NS) < 1._EB) THEN 
                  ZZ_EXTINCT(2) = ZZ_EXTINCT(2) + ZZ_MIXED_IN(NS) ! lumped oxidizer
               ENDIF
               OX_COUNT(NS) = OX_COUNT(NS) + 1._EB
               F_A_EXTINCT = F_A_EXTINCT + ABS(RNN%NU_MW_O_MW_F(NS))
            ENDIF
         ENDIF
      ENDDO
   ENDIF
ENDDO
ZZ_EXTINCT(3) = SUM(ZZ_DIL_EXTINCT)-ZZ_EXTINCT(2) ! lumped non fuel/oxidizer diluent

! Normalize fuel only composition
ZZ_FUEL_EXTINCT = ZZ_FUEL_EXTINCT/(SUM(ZZ_FUEL_EXTINCT)+TWO_EPSILON_EB)
ZZ_FUEL_EXTINCT = ZZ_FUEL_EXTINCT/(FUEL_COUNT+TWO_EPSILON_EB)

DO NRR = 1,N_REACTIONS
   RNN => REACTION(NRR)
   HOC_EXTINCT = HOC_EXTINCT+ZZ_FUEL_EXTINCT(RNN%FUEL_SMIX_INDEX)*RNN%HEAT_OF_COMBUSTION
   AIT_EXTINCT = AIT_EXTINCT+ZZ_FUEL_EXTINCT(RNN%FUEL_SMIX_INDEX)*RNN%AUTO_IGNITION_TEMPERATURE
ENDDO
   
IF (TMP_MIXED_ZONE < AIT_EXTINCT) THEN
   EXTINCT_2 = .TRUE.
ELSE     
   DZ_FUEL = 0._EB
   DZ_AIR = 0._EB
   DZ_NONFUEL = 0._EB
   ! Search reactants to find limiting reactant and express it as fuel mass. This is the amount of fuel that can burn.
   DZ_FUEL = MIN(ZZ_EXTINCT(1),(FAST_COUNT/F_A_EXTINCT)*ZZ_EXTINCT(2))
   
   ! Get the specific heat for the fuel at the current and critical flame temperatures
   CALL GET_SENSIBLE_ENTHALPY(ZZ_FUEL_EXTINCT,H_F_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_FUEL_EXTINCT,H_F_N,RNN%CRIT_FLAME_TMP)
   
   ! Any non-burning fuel from each reaction can act as a diluent
   DO NRR = 1,N_REACTIONS
      RNN => REACTION(NRR)
      DZ_FRAC_F(NRR) = DZ_F(NRR)/MAX(SUM(DZ_F),TWO_EPSILON_EB)
      DO NS = 0,N_TRACKED_SPECIES
            IF (NS == RNN%FUEL_SMIX_INDEX) &
            ZZ_DIL_EXTINCT(NS) = ZZ_MIXED_IN(NS) - DZ_F(NRR)*DZ_FRAC_F(NRR)
      ENDDO
   ENDDO
   
   ! Normalize diluent only composition
   ZZ_DIL_EXTINCT = ZZ_DIL_EXTINCT/SUM(ZZ_DIL_EXTINCT)

   ! Get the specific heat for the fuel and diluent at the current and critical flame temperatures
   CALL GET_SENSIBLE_ENTHALPY(ZZ_FUEL_EXTINCT,H_F_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_DIL_EXTINCT,H_G_0,TMP_MIXED_ZONE)
   H_F_N = 0._EB
   H_G_N = 0._EB
   DO NRR = 1,N_REACTIONS
      RNN => REACTION(NRR)
      IF (.NOT. RNN%FAST_CHEMISTRY) CYCLE   
      CALL GET_SENSIBLE_ENTHALPY(ZZ_FUEL_EXTINCT,H_F_N_TEMP,RNN%CRIT_FLAME_TMP)
      H_F_N = H_F_N + ZZ_FUEL_EXTINCT(RNN%FUEL_SMIX_INDEX)*H_F_N_TEMP
      CALL GET_SENSIBLE_ENTHALPY(ZZ_DIL_EXTINCT,H_G_N_TEMP,RNN%CRIT_FLAME_TMP)
      H_G_N = H_G_N + ZZ_FUEL_EXTINCT(RNN%FUEL_SMIX_INDEX)*H_G_N_TEMP
   ENDDO
   ! Find how much oxidizer is needed.
   DZ_AIR = DZ_FUEL*(F_A_EXTINCT/FAST_COUNT)

   ! Determine how much "non-fuel" is needed to provide the limting reactant.
   DZ_NONFUEL = DZ_AIR + (DZ_AIR/ZZ_EXTINCT(2))*(ZZ_EXTINCT(3) + ZZ_EXTINCT(1)-DZ_FUEL)

   ! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp.
   IF (DZ_FUEL*H_F_0 + DZ_NONFUEL*H_G_0 + DZ_FUEL*HOC_EXTINCT < &
        DZ_FUEL*H_F_N + DZ_NONFUEL*H_G_N) EXTINCT_2 = .TRUE.
ENDIF

END FUNCTION EXTINCT_2


RECURSIVE SUBROUTINE COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_MIXED_IN,I,J,K,DT_SUB,TMP_MIXED_ZONE,EXTINCT)
USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL,GET_SPECIFIC_GAS_CONSTANT,GET_GIBBS_FREE_ENERGY
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
REAL(EB), INTENT(IN) :: ZZ_MIXED_IN(0:N_TRACKED_SPECIES),DT_SUB,TMP_MIXED_ZONE
INTEGER, INTENT(IN) :: I,J,K
LOGICAL, INTENT(IN) :: EXTINCT(1:N_REACTIONS)
REAL(EB), INTENT(INOUT) :: RATE_CONSTANT(1:N_REACTIONS)
REAL(EB) :: YY_PRIMITIVE(1:N_SPECIES),DZ_F(1:N_REACTIONS),DZ_FR(1:N_REACTIONS),DZ_FRAC_F(1:N_REACTIONS),DZ_FRAC_FR(1:N_REACTIONS),&
            MASS_OX,MASS_OX_STOICH,AA(1:N_REACTIONS),EE(1:N_REACTIONS),EQ_RATIO,ZZ_MIXED_FR(0:N_TRACKED_SPECIES),RHO_HAT,GFE,&
            DZ_F_SUM,DZ_FR_SUM
REAL(EB), PARAMETER :: ZZ_MIN=1.E-10_EB
INTEGER :: NS,NRR
TYPE(REACTION_TYPE),POINTER :: RNN=>NULL()

ZZ_MIXED_FR = ZZ_MIXED_IN
MASS_OX = 0._EB
MASS_OX_STOICH = 0._EB
EQ_RATIO = 0._EB
DZ_F(:) = 0._EB
DZ_FR(:) = 0._EB
DZ_F_SUM = 0._EB
DZ_FR_SUM = 0._EB
DZ_FRAC_F(:) = 0._EB
DZ_FRAC_FR(:) = 0._EB

IF (TEMPERATURE_DEPENDENT_REACTION) THEN ! calculate rho(T) if necessary
   CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_MIXED_IN,RSUM(I,J,K))
   RHO_HAT = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*TMP_MIXED_ZONE)
ELSE
   RHO_HAT = RHO(I,J,K)
ENDIF

DO NRR = 1,N_REACTIONS
   RNN => REACTION(NRR)
   AA(NRR) = RNN%A
   EE(NRR) = RNN%E
   IF(RNN%REVERSE) THEN ! compute equilibrium constant
      CALL GET_GIBBS_FREE_ENERGY(RNN%NU,GFE,TMP_MIXED_ZONE)
      RNN%EQBM_CONS = EXP(-1.E6_EB*GFE/(R0*TMP_MIXED_ZONE))
   ENDIF
   IF(RNN%HEAT_OF_COMBUSTION > 0._EB) THEN
      DO NS = 0,N_TRACKED_SPECIES ! calculate oxygen
         IF (RNN%NU(NS) < 0._EB .AND. NS /= RNN%FUEL_SMIX_INDEX) THEN
            MASS_OX_STOICH = MASS_OX_STOICH + ABS(ZZ_MIXED_IN(RNN%FUEL_SMIX_INDEX)*RNN%NU_MW_O_MW_F(NS)) !Stoich mass O2
            MASS_OX = ZZ_MIXED_IN(NS) ! Mass O2 in cell
         ENDIF
      ENDDO
   ENDIF
ENDDO
EQ_RATIO = MASS_OX_STOICH/(MASS_OX + TWO_EPSILON_EB)

IF (ALL(REACTION(:)%FAST_CHEMISTRY) .AND. ALL(EXTINCT)) THEN
   RATE_CONSTANT(:) = 0._EB
ELSE   
   IF (N_REACTIONS > 1) THEN
      DO NRR = 1,N_REACTIONS
         RNN => REACTION(NRR)
         IF (RNN%FAST_CHEMISTRY .AND. RNN%HEAT_OF_COMBUSTION > 0._EB .AND. .NOT. EXTINCT(NRR)) THEN
            DO NS = 0,N_TRACKED_SPECIES
               IF (RNN%NU(NS) < 0._EB) ZZ_MIXED_FR(NS) = ZZ_MIXED_FR(NS) - ABS(ZZ_MIXED_IN(NS)/RNN%NU_MW_O_MW_F(NS))
               ZZ_MIXED_FR(NS) = MAX(0._EB,ZZ_MIXED_FR(NS))
            ENDDO
         ENDIF
      ENDDO
   ENDIF
   DO NRR = 1,N_REACTIONS
      RNN => REACTION(NRR)
      IF (.NOT. RNN%FAST_CHEMISTRY) THEN ! finite rate reactions
         CALL GET_MASS_FRACTION_ALL(ZZ_MIXED_FR,YY_PRIMITIVE)
         DZ_FR(NRR) = AA(NRR)*EXP(-EE(NRR)/(R0*TMP_MIXED_ZONE))*RHO_HAT**RNN%RHO_EXPONENT
         IF (ABS(RNN%N_T)>TWO_EPSILON_EB) DZ_FR(NRR)=DZ_FR(NRR)*TMP_MIXED_ZONE**RNN%N_T
         IF (ALL(RNN%N_S<-998._EB)) THEN
            DO NS=0,N_TRACKED_SPECIES
               IF(RNN%NU(NS) < 0._EB .AND. ZZ_MIXED_FR(NS) < ZZ_MIN) THEN
                  DZ_FR(NRR) = 0._EB
               ENDIF
            ENDDO
         ELSE
            DO NS=1,N_SPECIES
               IF(ABS(RNN%N_S(NS)) <= TWO_EPSILON_EB) CYCLE
               IF(RNN%N_S(NS)>= -998._EB) THEN
                  IF (YY_PRIMITIVE(NS) < ZZ_MIN) THEN
                     DZ_FR(NRR) = 0._EB
                  ELSE
                     DZ_FR(NRR) = YY_PRIMITIVE(NS)**RNN%N_S(NS)*DZ_FR(NRR)
                  ENDIF
               ENDIF
            ENDDO
         ENDIF
         DO NS = 0,N_TRACKED_SPECIES
            IF (RNN%NU(NS) < 0._EB) THEN
               DZ_FR(NRR) =(1._EB/RNN%EQBM_CONS)*DZ_FR(NRR)!*MIN(DZ_FR(NRR),-ZZ_MIXED_FR(NS)/RNN%NU_MW_O_MW_F(NS)/DT_SUB)!
            ENDIF
         ENDDO
      ELSE ! fast chemistry
         DZ_F(NRR) = 1.E10_EB
         DO NS = 0,N_TRACKED_SPECIES
            IF (RNN%NU(NS) < 0._EB) THEN
               DZ_F(NRR) = MIN(DZ_F(NRR),-ZZ_MIXED_IN(NS)/RNN%NU_MW_O_MW_F(NS))
            ENDIF
         ENDDO
      ENDIF
      IF (MASS_OX_STOICH > MASS_OX .AND. RNN%HEAT_OF_COMBUSTION > 0._EB) THEN
         DZ_F_SUM = DZ_F_SUM + DZ_F(NRR)
         DZ_FR_SUM = DZ_FR_SUM + DZ_FR(NRR)
      ENDIF
   ENDDO
   DO NRR = 1,N_REACTIONS
      RNN => REACTION(NRR) 
      IF (MASS_OX_STOICH > MASS_OX .AND. RNN%HEAT_OF_COMBUSTION > 0._EB) THEN 
         DZ_FRAC_F(NRR) = DZ_F(NRR)/MAX(DZ_F_SUM,TWO_EPSILON_EB)
         DZ_FRAC_FR(NRR) = DZ_FR(NRR)/MAX(DZ_FR_SUM,TWO_EPSILON_EB)
         IF (.NOT. RNN%FAST_CHEMISTRY) THEN
            RATE_CONSTANT(NRR) = DZ_FR(NRR)!*DZ_FRAC_FR(NRR)
         ELSE
            IF (.NOT. EXTINCT(NRR)) THEN
               RATE_CONSTANT(NRR) = DZ_F(NRR)*DZ_FRAC_F(NRR)/DT_SUB
            ELSE
               RATE_CONSTANT(NRR) = 0._EB
            ENDIF 
         ENDIF
      ELSE
         IF (.NOT. RNN%FAST_CHEMISTRY) THEN
            RATE_CONSTANT(NRR) = DZ_FR(NRR)
         ELSE
            IF (.NOT. EXTINCT(NRR)) THEN
               RATE_CONSTANT(NRR) = DZ_F(NRR)/DT_SUB
            ELSE
               RATE_CONSTANT(NRR) = 0._EB
            ENDIF          
         ENDIF
      ENDIF
   ENDDO
ENDIF   
RETURN 

END SUBROUTINE COMPUTE_RATE_CONSTANT

SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+2:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire
 
END MODULE FIRE

